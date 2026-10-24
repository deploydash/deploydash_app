import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/ui/layout/main_layout.dart';

import '../../_support/fake_analytics_service.dart';

/// [FlushableFakeAnalyticsService] recording the close sequence, proving the
/// session row lands before the flush pushes it out.
class _OrderedAnalyticsService extends FlushableFakeAnalyticsService {
  final calls = <String>[];

  @override
  void endSession() {
    calls.add('endSession');
    super.endSession();
  }

  @override
  Future<void> flush() async {
    calls.add('flush');
    await super.flush();
  }
}

void main() {
  testWidgets('MainLayout renders YaruWindowTitleBar and child', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: MainLayout(
            title: Text('Test Title'),
            child: Text('Content Body'),
          ),
        ),
      ),
    );

    // Verify TitleBar exists
    expect(find.byType(YaruWindowTitleBar), findsOneWidget);
    expect(find.text('Test Title'), findsOneWidget);

    // Verify Child content exists
    expect(find.text('Content Body'), findsOneWidget);
  });

  testWidgets('MainLayout flushes analytics exactly once on window detach', (
    WidgetTester tester,
  ) async {
    // Counting backend proving the close hook fires exactly once per detach.
    final analytics = FlushableFakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: MainLayout(
              title: Text('Test Title'),
              child: Text('Content Body'),
            ),
          ),
        ),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(analytics.flushCallCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();
      expect(analytics.flushCallCount, 1);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('MainLayout ends the session before flushing on detach', (
    WidgetTester tester,
  ) async {
    final analytics = _OrderedAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: MainLayout(
              title: Text('Test Title'),
              child: Text('Content Body'),
            ),
          ),
        ),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();

      expect(analytics.calls, ['endSession', 'flush']);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('MainLayout forwards every detach to the session hook', (
    WidgetTester tester,
  ) async {
    // No layout-level dedup: the backends own exactly-once, so each detach
    // still ends the session hook and flushes.
    final analytics = _OrderedAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: MainLayout(
              title: Text('Test Title'),
              child: Text('Content Body'),
            ),
          ),
        ),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();

      expect(analytics.calls, ['endSession', 'flush', 'endSession', 'flush']);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });
}
