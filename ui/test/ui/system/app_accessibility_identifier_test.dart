import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui/system/app_accessibility_identifier.dart';

/// Hosts identifier widgets in the minimum tree that produces semantics.
Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('wrapper publishes the stable platform identifier', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const AppAccessibilityIdentifier(
          identifier: 'package-boundary-control',
          child: Text('Control'),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.identifier == 'package-boundary-control',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('key helper prefers the field key', (tester) async {
    await tester.pumpWidget(
      _host(
        appAccessibilityIdentifierForKeys(
          widgetKey: const Key('outer-control'),
          fieldKey: const Key('inner-field'),
          child: const Text('Field'),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.identifier == 'inner-field',
      ),
      findsOneWidget,
    );
  });

  testWidgets('key helper falls back to the widget key', (tester) async {
    await tester.pumpWidget(
      _host(
        appAccessibilityIdentifierForKeys(
          widgetKey: const Key('outer-control'),
          fieldKey: null,
          child: const Text('Field'),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.identifier == 'outer-control',
      ),
      findsOneWidget,
    );
  });

  testWidgets('key helper leaves non-string keys unwrapped', (tester) async {
    const child = Text('Field');
    final wrapped = appAccessibilityIdentifierForKeys(
      widgetKey: GlobalKey(),
      fieldKey: null,
      child: child,
    );

    expect(identical(wrapped, child), isTrue);
    await tester.pumpWidget(_host(wrapped));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.identifier != null,
      ),
      findsNothing,
    );
  });
}
