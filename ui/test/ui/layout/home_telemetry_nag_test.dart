import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/telemetry_prompt.dart';
import 'package:ui/ui/layout/home_telemetry_nag_card.dart';

void main() {
  group('telemetryPromptFor', () {
    test('stays hidden before the first deploy', () {
      expect(
        telemetryPromptFor(
          firstDeploySucceededAt: null,
          telemetryEnabled: null,
          telemetryNagShownAt: null,
        ),
        isNull,
      );
    });

    test('nags once after the first deploy while opted out', () {
      final prompt = telemetryPromptFor(
        firstDeploySucceededAt: DateTime.utc(2026, 9, 11, 12),
        telemetryEnabled: false,
        telemetryNagShownAt: null,
      );

      expect(prompt, isNotNull);
      expect(prompt!.visible, isTrue);
      expect(prompt.moment, TelemetryMoment.homeNag);
    });

    test('stays hidden while reporting is on', () {
      for (final enabled in <bool?>[null, true]) {
        expect(
          telemetryPromptFor(
            firstDeploySucceededAt: DateTime.utc(2026, 9, 11, 12),
            telemetryEnabled: enabled,
            telemetryNagShownAt: null,
          ),
          isNull,
          reason: 'telemetryEnabled=$enabled',
        );
      }
    });

    test('stays hidden once the nag has been shown', () {
      expect(
        telemetryPromptFor(
          firstDeploySucceededAt: DateTime.utc(2026, 9, 11, 12),
          telemetryEnabled: false,
          telemetryNagShownAt: DateTime.utc(2026, 9, 12),
        ),
        isNull,
      );
    });
  });

  testWidgets('nag card shares and dismisses through its callbacks', (
    WidgetTester tester,
  ) async {
    var shareCount = 0;
    var dismissCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeTelemetryNagCard(
            onShare: () => shareCount += 1,
            onDismiss: () => dismissCount += 1,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('home-telemetry-nag-card')), findsOneWidget);
    expect(find.text('Help improve Deploy Dash'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-telemetry-nag-share-button')));
    await tester.pump();
    expect(shareCount, 1);
    expect(dismissCount, 0);

    await tester.tap(
      find.byKey(const Key('home-telemetry-nag-dismiss-button')),
    );
    await tester.pump();
    expect(shareCount, 1);
    expect(dismissCount, 1);
  });
}
