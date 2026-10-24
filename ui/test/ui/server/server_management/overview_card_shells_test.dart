import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// D-57 (T-015) characterization: the overview summary/metric card shells +
/// throughput bars render byte-identical geometry before and after the
/// `_SummaryCardShell`/`_MetricShell`/`_ThroughputBar` extraction.
///
/// The card widgets are library-private, so the test pins them through the
/// text they render: each anchor text resolves its card-shell Container via
/// [find] ancestor lookup, then asserts padding, radius, border alpha, and
/// (for the P1 pair) the fixed 220x132 footprint.
void main() {
  ensureSqliteRuntimeAvailable();

  Future<void> pumpMetricsOverview(WidgetTester tester) async {
    final sshService = OverviewMetricsSshService(
      succeedOverview: true,
      message: 'Metrics fetched from sysstat.',
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.byKey(const Key('overview-refresh-button')));
    await tester.pumpAndSettle();
    expect(find.text('Uptime'), findsOneWidget);
  }

  Container shellOf(WidgetTester tester, Finder anchor) {
    final shells = tester
        .widgetList<Container>(
          find.ancestor(of: anchor, matching: find.byType(Container)),
        )
        .where((c) => c.decoration is BoxDecoration)
        .toList(growable: false);
    expect(shells.length, 1, reason: 'anchor resolves one shell Container');
    return shells.single;
  }

  BoxDecoration decorationOf(Container shell) =>
      shell.decoration! as BoxDecoration;

  Color expectedBorder(WidgetTester tester, Finder anchor, double alpha) {
    final context = tester.element(anchor);
    return Theme.of(context).dividerColor.withValues(alpha: alpha);
  }

  testWidgets('P1 gauge + info cards share the 220x132 shell', (
    WidgetTester tester,
  ) async {
    await pumpMetricsOverview(tester);

    for (final title in ['CPU', 'Uptime']) {
      final anchor = find.text(title);
      expect(anchor, findsOneWidget);
      final shell = shellOf(tester, anchor);
      expect(shell.constraints?.maxWidth, 220);
      expect(shell.constraints?.maxHeight, 132);
      expect(shell.padding, const EdgeInsets.all(16));
      final decoration = decorationOf(shell);
      expect(decoration.borderRadius, BorderRadius.circular(12));
      final border = decoration.border! as Border;
      expect(border.top.color, expectedBorder(tester, anchor, 0.4));
    }
  });

  testWidgets('P2 compact tiles keep padding + subtle-conditional alpha', (
    WidgetTester tester,
  ) async {
    await pumpMetricsOverview(tester);

    final cases = {
      'Primary interface': 0.25, // subtle: true
      'Receive': 0.35, // subtle: false
    };
    for (final entry in cases.entries) {
      final anchor = find.text(entry.key);
      expect(anchor, findsOneWidget);
      final shell = shellOf(tester, anchor);
      expect(
        shell.padding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );
      final decoration = decorationOf(shell);
      expect(decoration.borderRadius, BorderRadius.circular(10));
      final border = decoration.border! as Border;
      expect(border.top.color, expectedBorder(tester, anchor, entry.value));
    }
  });

  testWidgets('P2 dual-throughput row keeps shell + paired bars', (
    WidgetTester tester,
  ) async {
    await pumpMetricsOverview(tester);
    await tester.drag(
      find.byKey(const Key('server-management-overview-tab')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All network interfaces'));
    await tester.pumpAndSettle();

    final anchor = find.text('RX 12.5 kB/s');
    expect(anchor, findsOneWidget);
    final shell = shellOf(tester, anchor);
    expect(
      shell.padding,
      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
    final decoration = decorationOf(shell);
    expect(decoration.borderRadius, BorderRadius.circular(10));
    final border = decoration.border! as Border;
    expect(border.top.color, expectedBorder(tester, anchor, 0.25));

    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.descendant(
            of: find.ancestor(of: anchor, matching: find.byType(Container)),
            matching: find.byType(LinearProgressIndicator),
          ),
        )
        .toList(growable: false);
    expect(bars.length, 2);
    final context = tester.element(anchor);
    final scheme = Theme.of(context).colorScheme;
    final expectedColors = [scheme.primary, Colors.green];
    for (var i = 0; i < 2; i++) {
      expect(bars[i].minHeight, 6);
      expect(bars[i].color, expectedColors[i]);
      expect(
        bars[i].backgroundColor,
        expectedColors[i].withValues(alpha: 0.14),
      );
      final clip = tester.widget<ClipRRect>(
        find
            .ancestor(
              of: find.byWidget(bars[i]),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(clip.borderRadius, BorderRadius.circular(99));
    }
  });

  testWidgets('P2 utilization row keeps shell', (WidgetTester tester) async {
    await pumpMetricsOverview(tester);
    await tester.drag(
      find.byKey(const Key('server-management-overview-tab')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All storage devices'));
    await tester.pumpAndSettle();

    final anchor = find.text('Read 4.0 kB/s • Write 2.0 kB/s • Used 9.0%');
    expect(anchor, findsOneWidget);
    final shell = shellOf(tester, anchor);
    expect(
      shell.padding,
      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
    final decoration = decorationOf(shell);
    expect(decoration.borderRadius, BorderRadius.circular(10));
    final border = decoration.border! as Border;
    expect(border.top.color, expectedBorder(tester, anchor, 0.25));
  });
}
