import 'package:ui/ui/system/app_window_title.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugOverrideAppWindowTitleSetter(null));

  testWidgets('window title reports screen changes once', (tester) async {
    final titles = <String>[];
    debugOverrideAppWindowTitleSetter((title) async => titles.add(title));

    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Home',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('first'),
        ),
      ),
    );
    await tester.pump();
    expect(titles, <String>['Deploy Dash - Home']);

    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Home',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('second'),
        ),
      ),
    );
    await tester.pump();
    expect(titles, hasLength(1));

    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Review server',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('third'),
        ),
      ),
    );
    await tester.pump();
    expect(titles.last, 'Deploy Dash - Review server');
  });

  testWidgets('window title failures do not interrupt the product UI', (
    tester,
  ) async {
    debugOverrideAppWindowTitleSetter(
      (_) => Future<void>.error(StateError('native title unavailable')),
    );

    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Unlock',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('still visible'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('still visible'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen transitions and disposal keep the latest title stable', (
    tester,
  ) async {
    final titles = <String>[];
    debugOverrideAppWindowTitleSetter((title) async => titles.add(title));

    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Create app database',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('create'),
        ),
      ),
    );
    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Home',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('home'),
        ),
      ),
    );
    await tester.pump();
    expect(titles, <String>[
      'Deploy Dash - Create app database',
      'Deploy Dash - Home',
    ]);

    titles.clear();
    await tester.pumpWidget(
      const AppWindowTitle(
        screen: 'Unlock',
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('unlock'),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(titles, <String>['Deploy Dash - Unlock']);
  });
}
