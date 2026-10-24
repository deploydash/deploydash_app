import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/ui/project/workspace/app/app_deployment_failure_card.dart';

/// Builds valid typed evidence while allowing each presentation state to vary.
DeployFailureEvidence failureEvidence({
  DeployFailurePhase phase = DeployFailurePhase.build,
  DeployFailureCompleteness completeness = DeployFailureCompleteness.diagnostic,
  List<String> lines = const <String>['compiler failed'],
  DeployFailureProbe? probe,
}) {
  return DeployFailureEvidence(
    phase: phase,
    source: DeployFailureSource.failedOperation,
    completeness: completeness,
    lines: lines,
    probe: probe,
  );
}

/// Pumps the focused card in the same scrollable constraints as its workspace.
Future<void> pumpFailureCard(
  WidgetTester tester, {
  required DeployFailureEvidence evidence,
  Future<void> Function(String details)? onCopyDetails,
  VoidCallback? onOpenLogs,
  String statusMessage = 'The deployment could not finish.',
  String? suggestedNextStep,
  Size size = const Size(800, 700),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: AppDeployFailureCard(
                evidence: evidence,
                statusMessage: statusMessage,
                onCopyDetails: onCopyDetails ?? (_) async {},
                onOpenLogs: onOpenLogs,
                suggestedNextStep: suggestedNextStep,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('phase labels use one stable presentation mapping', () {
    expect(
      DeployFailurePhase.values.map(deployFailurePhaseLabel).toList(),
      <String?>[
        'preparation',
        'code download',
        'build',
        'app startup',
        'app readiness check',
        'traffic switch',
        'public readiness check',
        'rollback',
        'deployment',
        null,
      ],
    );
    expect(
      deployFailureHeading(DeployFailurePhase.unknown),
      'Deployment stopped',
    );
  });

  test('probe facts fill only the remaining twelve-line budget', () {
    const probe = DeployFailureProbe(
      path: '/health',
      curlExit: 7,
      httpStatus: 503,
    );
    expect(
      deployFailureOutputLines(
        failureEvidence(lines: const <String>[], probe: probe),
      ),
      const <String>[
        'Probe path: /health',
        'Probe exit code: 7',
        'HTTP status: 503',
      ],
    );
    expect(
      deployFailureOutputLines(
        failureEvidence(
          lines: List<String>.generate(10, (index) => 'line $index'),
          probe: probe,
        ),
      ),
      <String>[
        ...List<String>.generate(10, (index) => 'line $index'),
        'Probe path: /health',
        'Probe exit code: 7',
      ],
    );
    expect(
      deployFailureOutputLines(
        failureEvidence(
          lines: List<String>.generate(12, (index) => 'line $index'),
          probe: probe,
        ),
      ),
      List<String>.generate(12, (index) => 'line $index'),
    );
    expect(
      deployFailureOutputLines(failureEvidence(lines: const <String>[])),
      isEmpty,
    );
  });

  test('copy text separates status, evidence, and honest fallbacks', () {
    expect(
      deployFailureCopyDetails(
        evidence: failureEvidence(lines: const <String>['first', 'second']),
        statusMessage: ' Build failed. ',
      ),
      'Deployment stopped during build\n'
      'Build failed.\n'
      'Relevant failure output\n'
      'first\n'
      'second',
    );
    expect(
      deployFailureCopyDetails(
        evidence: failureEvidence(
          phase: DeployFailurePhase.repositorySync,
          completeness: DeployFailureCompleteness.boundaryOnly,
          lines: const <String>[],
        ),
        statusMessage: ' ',
      ),
      'Deployment stopped during code download\n'
      'The code download operation failed, but it did not return diagnostic output.',
    );
    expect(
      deployFailureFallbackMessage(
        failureEvidence(
          phase: DeployFailurePhase.unknown,
          completeness: DeployFailureCompleteness.boundaryOnly,
          lines: const <String>[],
        ),
      ),
      'The deployment operation failed, but it did not return diagnostic output.',
    );
  });

  testWidgets('diagnostic output is ordered, selectable, and monospace', (
    WidgetTester tester,
  ) async {
    final lines = List<String>.generate(12, (index) => 'line ${index + 1}');
    await pumpFailureCard(tester, evidence: failureEvidence(lines: lines));

    expect(find.text('Deployment stopped during build'), findsOneWidget);
    expect(find.text('Relevant failure output'), findsOneWidget);
    final output = tester.widget<SelectableText>(
      find.byKey(const Key('deploy-failure-output-text')),
    );
    expect(output.data, lines.join('\n'));
    expect(output.style?.fontFamily, 'monospace');
    expect(find.byKey(const Key('deploy-failure-fallback')), findsNothing);
  });

  testWidgets('boundary-only and unavailable states use prose, not code', (
    WidgetTester tester,
  ) async {
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(
        completeness: DeployFailureCompleteness.boundaryOnly,
        lines: const <String>[],
      ),
    );
    expect(
      find.text(
        'The build operation failed, but it did not return diagnostic output.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('deploy-failure-output')), findsNothing);

    await pumpFailureCard(
      tester,
      evidence: failureEvidence(
        completeness: DeployFailureCompleteness.unavailable,
        lines: const <String>[],
      ),
    );
    expect(
      find.text(
        'The deployment ended before diagnostic output could be recovered.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('deploy-failure-output')), findsNothing);

    await pumpFailureCard(
      tester,
      evidence: failureEvidence(
        completeness: DeployFailureCompleteness.unknown,
        lines: const <String>[],
      ),
    );
    expect(
      find.text(
        'The deployment ended before diagnostic output could be recovered.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('unknown phase uses a generic heading', (
    WidgetTester tester,
  ) async {
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(phase: DeployFailurePhase.unknown),
    );

    expect(find.text('Deployment stopped'), findsOneWidget);
    expect(find.textContaining('during unknown'), findsNothing);
  });

  testWidgets('long output survives narrow width and 200 percent text', (
    WidgetTester tester,
  ) async {
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(
        lines: <String>[
          'compiler:${List<String>.filled(24, ' very-long-path-segment').join()}',
        ],
      ),
      size: const Size(280, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('deploy-failure-output-text')), findsOneWidget);
    expect(find.text('Copy details'), findsOneWidget);
    expect(find.text('Open deployment logs'), findsOneWidget);
  });

  testWidgets('copy action uses typed content and confirms completion', (
    WidgetTester tester,
  ) async {
    String? copied;
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(lines: const <String>['safe output']),
      onCopyDetails: (details) async {
        copied = details;
      },
      onOpenLogs: () {},
    );

    await tester.tap(find.byKey(const Key('deploy-failure-copy-button')));
    await tester.pump();

    expect(copied, contains('Relevant failure output\nsafe output'));
    expect(find.text('Deployment details copied.'), findsOneWidget);
  });

  testWidgets('keyboard activation reaches both named actions', (
    WidgetTester tester,
  ) async {
    var copied = false;
    var opened = false;
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(),
      onCopyDetails: (_) async {
        copied = true;
      },
      onOpenLogs: () {
        opened = true;
      },
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(copied, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('async copy does not show feedback after disposal', (
    WidgetTester tester,
  ) async {
    final copyCompleter = Completer<void>();
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(),
      onCopyDetails: (_) => copyCompleter.future,
    );

    await tester.tap(find.byKey(const Key('deploy-failure-copy-button')));
    await tester.pumpWidget(const SizedBox.shrink());
    copyCompleter.complete();
    await tester.pump();

    expect(find.text('Deployment details copied.'), findsNothing);
  });

  testWidgets('hint remains separate from status and evidence', (
    WidgetTester tester,
  ) async {
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(),
      suggestedNextStep: 'Check that the generated file is committed.',
    );

    expect(find.text('Suggested next step'), findsOneWidget);
    expect(
      find.byKey(const Key('deploy-failure-suggested-next-step')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('deploy-failure-output-text')),
          )
          .data,
      isNot(contains('generated file')),
    );

    await pumpFailureCard(
      tester,
      evidence: failureEvidence(),
      suggestedNextStep: '   ',
    );
    expect(find.text('Suggested next step'), findsNothing);
  });

  testWidgets('semantics expose one region and named actions', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpFailureCard(
      tester,
      evidence: failureEvidence(),
      onOpenLogs: () {},
    );

    final region = tester.getSemantics(
      find.byKey(const Key('deploy-failure-card')),
    );
    expect(region.label, startsWith('Deployment failure details'));
    expect(
      tester
          .getSemantics(find.byKey(const Key('deploy-failure-copy-button')))
          .label,
      contains('Copy details'),
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const Key('deploy-failure-open-logs-button')),
          )
          .label,
      contains('Open deployment logs'),
    );
    semantics.dispose();
  });
}
