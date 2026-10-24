import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui/system/app_cards.dart';

void main() {
  group('AppCard', () {
    Future<Container> pumpCard(
      WidgetTester tester, {
      Key? key,
      EdgeInsetsGeometry margin = const EdgeInsets.only(bottom: 8),
      EdgeInsetsGeometry padding = const EdgeInsets.all(12),
      double radius = 8,
      Color? borderColor,
      Color? fillColor,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppCard(
              key: key,
              margin: margin,
              padding: padding,
              radius: radius,
              borderColor: borderColor,
              fillColor: fillColor,
              child: const Text('card body'),
            ),
          ),
        ),
      );
      return tester.widget<Container>(
        find.ancestor(
          of: find.text('card body'),
          matching: find.byType(Container),
        ),
      );
    }

    testWidgets('defaults to the bordered history-entry set', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppCard(child: Text('card body'))),
        ),
      );

      final card = tester.widget<Container>(
        find.ancestor(
          of: find.text('card body'),
          matching: find.byType(Container),
        ),
      );
      expect(card.margin, const EdgeInsets.only(bottom: 8));
      expect(card.padding, const EdgeInsets.all(12));
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(8));
      expect(decoration.border, isNull);
      expect(decoration.color, isNull);
    });

    testWidgets('carries a key, border color, and full width', (tester) async {
      final card = await pumpCard(
        tester,
        key: const Key('history-entry-0'),
        borderColor: Colors.purple,
      );

      expect(find.byKey(const Key('history-entry-0')), findsOneWidget);
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.border, Border.all(color: Colors.purple));
    });

    testWidgets('expands to the available width', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: AppCard(child: Text('card body'))),
        ),
      );

      // The default test surface is 800 wide; a card without an infinite
      // width would shrink to its child instead.
      expect(tester.getSize(find.byType(AppCard)).width, 800);
    });

    testWidgets('honors the user-card set', (tester) async {
      final card = await pumpCard(
        tester,
        margin: const EdgeInsets.only(bottom: 10),
        radius: 10,
        borderColor: Colors.teal,
      );

      expect(card.margin, const EdgeInsets.only(bottom: 10));
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(10));
      expect(decoration.border, Border.all(color: Colors.teal));
    });

    testWidgets('honors the pad-16 connection-card set', (tester) async {
      final card = await pumpCard(
        tester,
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(16),
        radius: 12,
        borderColor: Colors.teal,
      );

      expect(card.margin, EdgeInsets.zero);
      expect(card.padding, const EdgeInsets.all(16));
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(12));
    });

    testWidgets('honors the filled output-box set', (tester) async {
      final card = await pumpCard(
        tester,
        margin: EdgeInsets.zero,
        fillColor: Colors.grey,
      );

      expect(card.margin, EdgeInsets.zero);
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.color, Colors.grey);
      expect(decoration.border, isNull);
    });
  });
}
