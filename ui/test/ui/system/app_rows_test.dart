import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui/system/app_rows.dart';

void main() {
  group('AppLabeledValueRow', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      double width = 120,
      TextStyle? labelStyle,
      TextStyle? valueStyle,
      CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
      bool valueSelectable = false,
      int? valueMaxLines,
      TextOverflow? valueOverflow,
      Widget? trailing,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppLabeledValueRow(
              label: 'Branch',
              value: 'main',
              width: width,
              labelStyle: labelStyle,
              valueStyle: valueStyle,
              crossAxisAlignment: crossAxisAlignment,
              valueSelectable: valueSelectable,
              valueMaxLines: valueMaxLines,
              valueOverflow: valueOverflow,
              trailing: trailing,
            ),
          ),
        ),
      );
    }

    testWidgets('lays out label cell, gap, and value with defaults', (
      tester,
    ) async {
      await pumpRow(tester);

      final row = tester.widget<Row>(find.byType(Row));
      expect(row.crossAxisAlignment, CrossAxisAlignment.start);
      final boxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList(growable: false);
      expect(boxes[0].width, 120);
      expect(boxes[1].width, 8);

      final context = tester.element(find.byType(AppLabeledValueRow));
      final label = tester.widget<Text>(find.text('Branch'));
      expect(label.style?.fontWeight, FontWeight.w600);
      expect(
        label.style?.color,
        Theme.of(context).colorScheme.onSurfaceVariant,
      );
      final value = tester.widget<Text>(find.text('main'));
      expect(value.style, Theme.of(context).textTheme.bodyMedium);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('defaults to the common row set', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppLabeledValueRow(label: 'Branch', value: 'main'),
          ),
        ),
      );

      final row = tester.widget<Row>(find.byType(Row));
      expect(row.crossAxisAlignment, CrossAxisAlignment.start);
      expect(row.children.length, 3);
      final boxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList(growable: false);
      expect(boxes[0].width, 120);
      expect(boxes[1].width, 8);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('honors an explicit label width', (tester) async {
      await pumpRow(tester, width: 96);

      final boxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList(growable: false);
      expect(boxes[0].width, 96);
      expect(boxes[1].width, 8);
    });

    testWidgets('honors explicit styles and alignment', (tester) async {
      const labelStyle = TextStyle(fontWeight: FontWeight.w600);
      const valueStyle = TextStyle(fontSize: 10);

      await pumpRow(
        tester,
        width: 110,
        labelStyle: labelStyle,
        valueStyle: valueStyle,
        crossAxisAlignment: CrossAxisAlignment.center,
      );

      final row = tester.widget<Row>(find.byType(Row));
      expect(row.crossAxisAlignment, CrossAxisAlignment.center);
      expect(tester.widget<Text>(find.text('Branch')).style, labelStyle);
      expect(tester.widget<Text>(find.text('main')).style, valueStyle);
    });

    testWidgets('renders a selectable value on request', (tester) async {
      await pumpRow(tester, valueSelectable: true);

      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('clamps the value to max lines with overflow', (tester) async {
      await pumpRow(
        tester,
        valueMaxLines: 1,
        valueOverflow: TextOverflow.ellipsis,
      );

      final value = tester.widget<Text>(find.text('main'));
      expect(value.maxLines, 1);
      expect(value.overflow, TextOverflow.ellipsis);
    });

    testWidgets('packs rows gapless on request', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppLabeledValueRow(label: 'Branch', value: 'main', gap: 0),
          ),
        ),
      );

      final boxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .toList(growable: false);
      expect(boxes[1].width, 0);
    });

    testWidgets('appends a trailing widget after the value', (tester) async {
      await pumpRow(
        tester,
        trailing: const IconButton(
          tooltip: 'Open URL',
          onPressed: null,
          icon: Icon(Icons.open_in_new),
        ),
      );

      expect(find.byTooltip('Open URL'), findsOneWidget);
      final row = tester.widget<Row>(find.byType(Row));
      expect(row.children.length, 4);
    });
  });
}
