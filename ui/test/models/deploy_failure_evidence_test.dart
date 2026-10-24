import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the complete version-one wire shape so each test changes one rule.
Map<String, dynamic> validPayload({
  Object? phase = 'build',
  Object? source = 'failed_operation',
  Object? completeness = 'diagnostic',
  Object? lines = const <String>['build failed'],
  Object? failedStepId = 'release',
  Object? failedActionId = 'build',
  Object? probe,
}) => <String, dynamic>{
  'schema_version': 1,
  'phase': phase,
  'source': source,
  'completeness': completeness,
  'lines': lines,
  'failed_step_id': failedStepId,
  'failed_action_id': failedActionId,
  'probe': probe,
};

/// Creates typed evidence for equality checks without repeating its baseline.
DeployFailureEvidence evidence({
  DeployFailurePhase phase = DeployFailurePhase.build,
  DeployFailureSource source = DeployFailureSource.failedOperation,
  DeployFailureCompleteness completeness = DeployFailureCompleteness.diagnostic,
  List<String> lines = const <String>['build failed'],
  String? failedStepId = 'release',
  String? failedActionId = 'build',
  DeployFailureProbe? probe = const DeployFailureProbe(path: '/up'),
}) => DeployFailureEvidence(
  phase: phase,
  source: source,
  completeness: completeness,
  lines: lines,
  failedStepId: failedStepId,
  failedActionId: failedActionId,
  probe: probe,
);

/// Verifies the one tolerant decoder for the additive failure-evidence shape.
void main() {
  group('DeployFailureEvidence', () {
    test('decodes round trips and exposes one immutable envelope member', () {
      final payload = validPayload(
        phase: 'candidate_readiness',
        source: 'candidate_probe',
        lines: <String>['health check returned HTTP 503'],
        failedStepId: ' app_release ',
        failedActionId: ' candidate_readiness ',
        probe: <String, dynamic>{
          'path': ' /up ',
          'curl_exit': 22,
          'http_status': 503,
        },
      );
      final evidence = DeployFailureEvidence.fromEnvelope(<String, dynamic>{
        deployFailureEvidenceEnvelopeField: payload,
      });

      expect(evidence, isNotNull);
      expect(evidence!.phase, DeployFailurePhase.candidateReadiness);
      expect(evidence.source, DeployFailureSource.candidateProbe);
      expect(evidence.completeness, DeployFailureCompleteness.diagnostic);
      expect(evidence.lines, <String>['health check returned HTTP 503']);
      expect(evidence.failedStepId, 'app_release');
      expect(evidence.failedActionId, 'candidate_readiness');
      expect(
        evidence.probe,
        const DeployFailureProbe(path: '/up', curlExit: 22, httpStatus: 503),
      );
      expect(() => evidence.lines.add('mutate'), throwsUnsupportedError);
      expect(DeployFailureEvidence.fromPayload(evidence.toPayload()), evidence);
      expect(DeployFailureEvidence.envelopeMember(evidence), <String, dynamic>{
        deployFailureEvidenceEnvelopeField: evidence.toPayload(),
      });
      expect(DeployFailureEvidence.envelopeMember(null), isEmpty);
      expect(
        evidence.hashCode,
        DeployFailureEvidence.fromPayload(evidence.toPayload())!.hashCode,
      );
    });

    test('sanitizes lines before they enter clipboard-capable evidence', () {
      const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
      final decoded = DeployFailureEvidence.fromPayload(
        validPayload(
          lines: <String>[
            'Authorization: Bearer $canary',
            'compiler=/workspace/lib/main.dart code=ERR_BUILD_42',
          ],
        ),
      );

      expect(decoded, isNotNull);
      expect(decoded!.lines.join('\n'), isNot(contains(canary)));
      expect(decoded.lines.first, 'Authorization: Bearer ***');
      expect(
        decoded.lines.last,
        'compiler=/workspace/lib/main.dart code=ERR_BUILD_42',
      );
    });

    test('ignores missing malformed oversized and future payloads', () {
      final extraField = validPayload()..['future'] = true;
      final wrongSchemaType = validPayload()..['schema_version'] = true;
      final futureSchema = validPayload()..['schema_version'] = 2;
      final malformed = <Object?>[
        null,
        'not-a-map',
        <String, dynamic>{},
        extraField,
        wrongSchemaType,
        futureSchema,
        validPayload(phase: 1),
        validPayload(source: 1),
        validPayload(completeness: 1),
        validPayload(lines: 'not-a-list'),
        validPayload(lines: List<String>.filled(13, 'error')),
        validPayload(lines: <Object>['valid', 3]),
        validPayload(lines: <String>['   ']),
        validPayload(lines: <String>[''.padRight(6145, 'x')]),
        validPayload(failedStepId: 1),
        validPayload(failedStepId: ' '),
        validPayload(failedActionId: 1),
        validPayload(failedActionId: ' '),
        validPayload(probe: 'not-a-map'),
        validPayload(probe: <String, dynamic>{}),
        validPayload(probe: <String, dynamic>{'response_body': 'forbidden'}),
        validPayload(probe: <Object?, Object?>{1: '/up'}),
        validPayload(probe: <String, dynamic>{'path': 3}),
        validPayload(probe: <String, dynamic>{'path': 'health'}),
        validPayload(probe: <String, dynamic>{'curl_exit': '22'}),
        validPayload(probe: <String, dynamic>{'curl_exit': true}),
        validPayload(probe: <String, dynamic>{'curl_exit': -1}),
        validPayload(probe: <String, dynamic>{'curl_exit': 256}),
        validPayload(probe: <String, dynamic>{'http_status': '503'}),
        validPayload(probe: <String, dynamic>{'http_status': true}),
        validPayload(probe: <String, dynamic>{'http_status': 99}),
        validPayload(probe: <String, dynamic>{'http_status': 600}),
        validPayload(
          lines: const <String>[],
          failedStepId: null,
          failedActionId: null,
        ),
        validPayload(completeness: 'boundary_only'),
        validPayload(
          completeness: 'boundary_only',
          lines: const <String>[],
          probe: <String, dynamic>{'path': '/up'},
        ),
        validPayload(completeness: 'unavailable'),
        validPayload(
          completeness: 'unavailable',
          lines: const <String>[],
          probe: <String, dynamic>{'path': '/up'},
        ),
      ];

      for (final payload in malformed) {
        expect(
          DeployFailureEvidence.fromPayload(payload),
          isNull,
          reason: '$payload',
        );
      }
      expect(DeployFailureEvidence.fromEnvelope(<String, dynamic>{}), isNull);
    });

    test('round trips every phase and source including unknown values', () {
      const phases = <(String, DeployFailurePhase)>[
        ('prepare', DeployFailurePhase.prepare),
        ('repository_sync', DeployFailurePhase.repositorySync),
        ('build', DeployFailurePhase.build),
        ('candidate_start', DeployFailurePhase.candidateStart),
        ('candidate_readiness', DeployFailurePhase.candidateReadiness),
        ('traffic_switch', DeployFailurePhase.trafficSwitch),
        (
          'post_cutover_stabilization',
          DeployFailurePhase.postCutoverStabilization,
        ),
        ('rollback', DeployFailurePhase.rollback),
        ('engine', DeployFailurePhase.engine),
        ('future_phase', DeployFailurePhase.unknown),
      ];
      const sources = <(String, DeployFailureSource)>[
        ('failed_operation', DeployFailureSource.failedOperation),
        ('candidate_runtime', DeployFailureSource.candidateRuntime),
        ('candidate_probe', DeployFailureSource.candidateProbe),
        ('routed_probe', DeployFailureSource.routedProbe),
        ('exception', DeployFailureSource.exception),
        ('none', DeployFailureSource.none),
        ('future_source', DeployFailureSource.unknown),
      ];

      for (final (wire, typed) in phases) {
        final decoded = DeployFailureEvidence.fromPayload(
          validPayload(phase: wire),
        );
        expect(decoded?.phase, typed);
        expect(
          evidence(phase: typed).toPayload()['phase'],
          typed == DeployFailurePhase.unknown ? 'unknown' : wire,
        );
      }
      for (final (wire, typed) in sources) {
        final decoded = DeployFailureEvidence.fromPayload(
          validPayload(source: wire),
        );
        expect(decoded?.source, typed);
        expect(
          evidence(source: typed).toPayload()['source'],
          typed == DeployFailureSource.unknown ? 'unknown' : wire,
        );
      }
    });

    test(
      'round trips every completeness and accepts probe-only diagnostics',
      () {
        final diagnostic = DeployFailureEvidence.fromPayload(
          validPayload(
            lines: const <String>[],
            probe: <String, dynamic>{'http_status': 503},
          ),
        );
        final boundaryOnly = DeployFailureEvidence.fromPayload(
          validPayload(
            completeness: 'boundary_only',
            lines: const <String>[],
            failedStepId: null,
            failedActionId: null,
          ),
        );
        final unavailable = DeployFailureEvidence.fromPayload(
          validPayload(
            completeness: 'unavailable',
            lines: const <String>[],
            failedStepId: null,
            failedActionId: null,
          ),
        );
        final unknown = DeployFailureEvidence.fromPayload(
          validPayload(
            completeness: 'future_completeness',
            lines: const <String>[],
            failedStepId: null,
            failedActionId: null,
          ),
        );

        expect(diagnostic?.completeness, DeployFailureCompleteness.diagnostic);
        expect(
          boundaryOnly?.completeness,
          DeployFailureCompleteness.boundaryOnly,
        );
        expect(
          unavailable?.completeness,
          DeployFailureCompleteness.unavailable,
        );
        expect(unknown?.completeness, DeployFailureCompleteness.unknown);
        expect(
          evidence(
            completeness: DeployFailureCompleteness.boundaryOnly,
            lines: const <String>[],
            probe: null,
          ).toPayload()['completeness'],
          'boundary_only',
        );
        expect(
          evidence(
            completeness: DeployFailureCompleteness.unavailable,
            lines: const <String>[],
            probe: null,
          ).toPayload()['completeness'],
          'unavailable',
        );
        expect(
          evidence(
            completeness: DeployFailureCompleteness.unknown,
            lines: const <String>[],
            probe: null,
          ).toPayload()['completeness'],
          'unknown',
        );
        expect(evidence().toPayload()['completeness'], 'diagnostic');
      },
    );

    test('probe decoder accepts only bounded body-free facts', () {
      const empty = DeployFailureProbe();
      const path = DeployFailureProbe(path: '/up');
      const curlMinimum = DeployFailureProbe(curlExit: 0);
      const curlMaximum = DeployFailureProbe(curlExit: 255);
      const statusMinimum = DeployFailureProbe(httpStatus: 100);
      const statusMaximum = DeployFailureProbe(httpStatus: 599);

      expect(empty.toPayload(), isEmpty);
      expect(DeployFailureProbe.fromPayload(null), isNull);
      expect(DeployFailureProbe.fromPayload(<String, dynamic>{}), isNull);
      expect(DeployFailureProbe.fromPayload(path.toPayload()), path);
      expect(
        DeployFailureProbe.fromPayload(curlMinimum.toPayload()),
        curlMinimum,
      );
      expect(
        DeployFailureProbe.fromPayload(curlMaximum.toPayload()),
        curlMaximum,
      );
      expect(
        DeployFailureProbe.fromPayload(statusMinimum.toPayload()),
        statusMinimum,
      );
      expect(
        DeployFailureProbe.fromPayload(statusMaximum.toPayload()),
        statusMaximum,
      );
      expect(path, isNot(empty));
      expect(curlMinimum, isNot(curlMaximum));
      expect(statusMinimum, isNot(statusMaximum));
      expect(path, isNot('not-a-probe'));
      expect(path.hashCode, const DeployFailureProbe(path: '/up').hashCode);
    });

    test('value equality observes every evidence field and ordered line', () {
      final baseline = evidence(lines: const <String>['one', 'two']);
      final same = evidence(lines: const <String>['one', 'two']);

      expect(baseline, same);
      expect(baseline, isNot('not-evidence'));
      expect(baseline, isNot(evidence(phase: DeployFailurePhase.engine)));
      expect(baseline, isNot(evidence(source: DeployFailureSource.exception)));
      expect(
        baseline,
        isNot(
          evidence(
            completeness: DeployFailureCompleteness.unknown,
            lines: const <String>['one', 'two'],
          ),
        ),
      );
      expect(baseline, isNot(evidence(lines: const <String>['one'])));
      expect(baseline, isNot(evidence(lines: const <String>['one', 'three'])));
      expect(
        baseline,
        isNot(
          evidence(lines: const <String>['one', 'two'], failedStepId: null),
        ),
      );
      expect(
        baseline,
        isNot(
          evidence(lines: const <String>['one', 'two'], failedActionId: null),
        ),
      );
      expect(
        baseline,
        isNot(
          evidence(
            lines: const <String>['one', 'two'],
            probe: const DeployFailureProbe(path: '/health'),
          ),
        ),
      );
      expect(baseline.hashCode, same.hashCode);
    });
  });
}
