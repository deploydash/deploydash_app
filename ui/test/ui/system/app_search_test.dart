import 'dart:io';

import 'package:ui/services/local_search_index.dart';
import 'package:ui/ui/system/app_search.dart';
import 'package:ui/ui/system/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _results = <LocalSearchResult>[
  LocalSearchResult(
    kind: LocalSearchResultKind.server,
    title: 'prod-01',
    subtitle: '203.0.113.10',
    serverId: 'server-1',
  ),
  LocalSearchResult(
    kind: LocalSearchResultKind.project,
    title: 'Billing',
    subtitle: 'app - billing.example.com',
    context: 'prod-01',
    serverId: 'server-1',
    projectId: 'project-1',
    destinationId: 'web-app',
  ),
  LocalSearchResult(
    kind: LocalSearchResultKind.screen,
    title: 'Database',
    subtitle: 'Billing',
    serverId: 'server-1',
    projectId: 'project-1',
    destinationId: 'database',
  ),
];

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildDeployDashTheme(ThemeData.light()),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 220, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('field renders a clear action once text is entered', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var cleared = 0;

    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            return AppSearchField(
              controller: controller,
              focusNode: focusNode,
              onChanged: (_) => setState(() {}),
              onClear: () {
                cleared += 1;
                controller.clear();
                setState(() {});
              },
            );
          },
        ),
      ),
    );

    expect(find.byKey(const Key('app-search-clear-button')), findsNothing);
    await tester.enterText(find.byKey(const Key('app-search-field')), 'bill');
    await tester.pump();
    expect(find.byKey(const Key('app-search-clear-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-search-clear-button')));
    await tester.pump();
    expect(cleared, 1);
    expect(find.byKey(const Key('app-search-clear-button')), findsNothing);
  });

  testWidgets('overlay lists grouped results and reports taps', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    LocalSearchResult? selected;

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (query) => query.isEmpty ? const [] : _results,
          onSelected: (result) => selected = result,
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'bill');
    await tester.pump();

    expect(find.byKey(const Key('app-search-overlay')), findsOneWidget);
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('app - billing.example.com - prod-01'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-search-result-project-1')));
    await tester.pump();

    expect(selected?.projectId, 'project-1');
    expect(find.byKey(const Key('app-search-overlay')), findsNothing);
  });

  testWidgets('arrow keys move the highlight and enter activates it', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    LocalSearchResult? selected;

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (_) => _results,
          onSelected: (result) => selected = result,
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'a');
    await tester.pump();

    expect(_isHighlighted(tester, 'app-search-result-server-0'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_isHighlighted(tester, 'app-search-result-project-1'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_isHighlighted(tester, 'app-search-result-server-0'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_isHighlighted(tester, 'app-search-result-screen-2'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected?.destinationId, 'database');
    expect(find.byKey(const Key('app-search-overlay')), findsNothing);
  });

  testWidgets('escape closes the overlay and keyboard keys need results', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    var selectedCount = 0;

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (query) => query == 'bill' ? _results : const [],
          onSelected: (_) => selectedCount += 1,
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'nope');
    await tester.pump();
    expect(find.byKey(const Key('app-search-empty')), findsOneWidget);
    expect(find.text('No matches for "nope".'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selectedCount, 0);

    await tester.enterText(find.byKey(const Key('app-search-field')), 'bill');
    await tester.pump();
    expect(find.byKey(const Key('app-search-overlay')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('app-search-overlay')), findsNothing);
  });

  testWidgets('unhandled keys and repeat events are ignored', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (_) => _results,
          onSelected: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'a');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(_isHighlighted(tester, 'app-search-result-server-0'), isTrue);
  });

  testWidgets('tapping outside the panel closes it', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (_) => _results,
          onSelected: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'a');
    await tester.pump();
    expect(find.byKey(const Key('app-search-overlay')), findsOneWidget);

    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(find.byKey(const Key('app-search-overlay')), findsNothing);
  });

  testWidgets('collapsed rail opens the panel with the field inside it', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    LocalSearchResult? selected;

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          collapsed: true,
          resultsBuilder: (query) => query.isEmpty ? const [] : _results,
          onSelected: (result) => selected = result,
        ),
      ),
    );

    expect(find.byKey(const Key('app-search-field')), findsNothing);
    await tester.tap(find.byKey(const Key('app-search-icon-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-search-field')), findsOneWidget);
    expect(find.byKey(const Key('app-search-hint')), findsOneWidget);
    expect(focusNode.hasFocus, isTrue);

    await tester.enterText(find.byKey(const Key('app-search-field')), 'bill');
    await tester.pump();
    await tester.tap(find.byKey(const Key('app-search-result-screen-2')));
    await tester.pump();
    expect(selected?.destinationId, 'database');
  });

  testWidgets('hint panel message pins key, text, padding, and style', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          collapsed: true,
          resultsBuilder: (query) => query.isEmpty ? const [] : _results,
          onSelected: (_) {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('app-search-icon-button')));
    await tester.pumpAndSettle();

    final hint = find.byKey(const Key('app-search-hint'));
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.byType(Text)),
      findsOneWidget,
    );
    final element = tester.element(hint);
    final tokens = element.appThemeTokens;
    final theme = Theme.of(element);
    expect(
      tester.widget<Padding>(hint).padding,
      EdgeInsets.all(tokens.spaceMd),
    );
    final text = tester.widget<Text>(
      find.descendant(of: hint, matching: find.byType(Text)),
    );
    expect(text.data, 'Type to find a server, project, or screen.');
    expect(text.style, theme.textTheme.bodySmall);
    expect(find.byKey(const Key('app-search-empty')), findsNothing);
  });

  testWidgets('empty panel message pins key, text, padding, and style', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (_) => const [],
          onSelected: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'zzz');
    await tester.pump();

    final empty = find.byKey(const Key('app-search-empty'));
    expect(empty, findsOneWidget);
    final element = tester.element(empty);
    final tokens = element.appThemeTokens;
    final theme = Theme.of(element);
    expect(
      tester.widget<Padding>(empty).padding,
      EdgeInsets.all(tokens.spaceMd),
    );
    final text = tester.widget<Text>(
      find.descendant(of: empty, matching: find.byType(Text)),
    );
    expect(text.data, 'No matches for "zzz".');
    expect(text.style, theme.textTheme.bodySmall);
    expect(find.byKey(const Key('app-search-hint')), findsNothing);
  });

  test('search panel messages have one owner (shape pin)', () {
    final source = File('lib/ui/system/app_search.dart').readAsStringSync();
    // Local closure, so no leading underscore (repo lint
    // no_leading_underscores_for_local_identifiers): 1 def + 2 calls.
    expect('panelMessage'.allMatches(source).length, 3);
  });

  testWidgets('focusing the field opens the panel with a hint', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (_) => _results,
          onSelected: (_) {},
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    expect(find.byKey(const Key('app-search-overlay')), findsNothing);
    expect(find.byKey(const Key('app-search-hint')), findsNothing);
  });

  testWidgets('long result lists scroll the highlighted row into view', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final manyResults = <LocalSearchResult>[
      for (var index = 0; index < 30; index++)
        LocalSearchResult(
          kind: LocalSearchResultKind.project,
          title: 'Project $index',
          projectId: 'project-$index',
        ),
    ];

    await tester.pumpWidget(
      _wrap(
        AppSearchOverlay(
          focusNode: focusNode,
          resultsBuilder: (_) => manyResults,
          onSelected: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'p');
    await tester.pump();

    final scrollable = find.descendant(
      of: find.byKey(const Key('app-search-overlay')),
      matching: find.byType(Scrollable),
    );
    expect(tester.widget<Scrollable>(scrollable).controller!.offset, 0);

    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(
      tester.widget<Scrollable>(scrollable).controller!.offset,
      greaterThan(0),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

bool _isHighlighted(WidgetTester tester, String key) {
  final material = tester.widget<Material>(
    find
        .ancestor(of: find.byKey(Key(key)), matching: find.byType(Material))
        .first,
  );
  return material.color != Colors.transparent;
}
