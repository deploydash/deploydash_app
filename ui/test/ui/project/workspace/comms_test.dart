import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace email and domain placeholders.
///
/// One of sixteen files T-3.6.1 split `project_workspace_test.dart` into. That
/// file was 16,030 lines holding 230 tests in two groups: a directory's worth
/// of tests wearing a filename, which nobody could hold in view, so a coverage
/// gap in it was invisible by construction.
///
/// Fixtures and pump helpers live in
/// `_support/project_workspace_harness.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('project workspace email and domain placeholders', () {
    testWidgets('Email tab does not expose placeholder records or actions', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedServerProvider.overrideWithValue(serverWithEmailEnabled),
          ],
          child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(Tab, 'Email'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('email-unavailable-state')), findsOneWidget);
      expect(
        find.text('Email management is not available yet'),
        findsOneWidget,
      );
      expect(find.textContaining('@laravel.com'), findsNothing);
      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Domain tab does not expose placeholder records or actions', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedServerProvider.overrideWithValue(serverWithDomainEnabled),
          ],
          child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(Tab, 'Domain'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('domain-unavailable-state')), findsOneWidget);
      expect(
        find.text('Domain management is not available yet'),
        findsOneWidget,
      );
      expect(find.textContaining('203.0.113.'), findsNothing);
      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });
  }, skip: !sqliteAvailable);
}
