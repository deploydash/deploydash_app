import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// Postgres identifier validation pins (D-35).
///
/// The two form validators in `database_tab_logic.dart` share trim + bounds
/// (63/3) + check order and differ only in pattern, label, and
/// required-ness. These tests pin every message, both patterns, and the
/// length-over-pattern precedence through the dialogs that own the
/// validators, so the database-name delegate collapse can prove
/// message-identical behavior.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDatabaseTab(WidgetTester tester) async {
    final sshService = DatabaseWorkflowSshService(
      projectListResponse: const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'configured': true,
          'running': true,
        },
        'databases': <String>['alpha_db'],
        'users': <Map<String, dynamic>>[
          <String, dynamic>{
            'username': 'alpha_user',
            'database': 'alpha_db',
            'access_mode': 'read_write',
          },
        ],
      },
    );
    await pumpProjectWorkspace(
      tester,
      overrides: [
        selectedProjectProvider.overrideWithValue(selectedProject),
        selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
        sshServiceProvider.overrideWithValue(sshService),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, 'Database'));
    await tester.pumpAndSettle();
  }

  Future<void> openCreateDatabaseDialog(WidgetTester tester) async {
    await pumpDatabaseTab(tester);
    await tester.tap(find.byKey(const Key('database-create-button')));
    await tester.pumpAndSettle();
  }

  Future<void> openConnectUserDialog(WidgetTester tester) async {
    await pumpDatabaseTab(tester);
    await tester.drag(
      find.byKey(const Key('database-tab-scroll')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();
    final linkButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('database-link-button')),
    );
    linkButton.onPressed!.call();
    await tester.pumpAndSettle();
  }

  const nameField = Key('database-create-name-field');
  const usernameField = Key('database-connect-existing-username-field');

  group('postgres identifier validation (D-35 pins)', () {
    testWidgets('database name reports length bounds', (
      WidgetTester tester,
    ) async {
      await openCreateDatabaseDialog(tester);

      await tester.enterText(find.byKey(nameField), 'a' * 64);
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(
        find.text('Database name must be 63 characters or fewer.'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(nameField), 'ab');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(
        find.text('Database name must be at least 3 characters.'),
        findsOneWidget,
      );
    });

    // A failing validator always renders its message, so the absence of
    // every name error after submit proves the value validated. Each case
    // gets its own dialog: a valid submit closes it.
    testWidgets('database name allows a leading digit', (
      WidgetTester tester,
    ) async {
      await openCreateDatabaseDialog(tester);

      await tester.enterText(find.byKey(nameField), '1abc');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.text('Database name is required.'), findsNothing);
      expect(
        find.text('Database name must be 63 characters or fewer.'),
        findsNothing,
      );
      expect(
        find.text('Database name must be at least 3 characters.'),
        findsNothing,
      );
      expect(
        find.text(
          'Database name may only use lowercase letters, numbers, or underscores.',
        ),
        findsNothing,
      );
    });

    testWidgets('database name allows a leading underscore', (
      WidgetTester tester,
    ) async {
      await openCreateDatabaseDialog(tester);

      await tester.enterText(find.byKey(nameField), '_abc');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.text('Database name is required.'), findsNothing);
      expect(
        find.text('Database name must be 63 characters or fewer.'),
        findsNothing,
      );
      expect(
        find.text('Database name must be at least 3 characters.'),
        findsNothing,
      );
      expect(
        find.text(
          'Database name may only use lowercase letters, numbers, or underscores.',
        ),
        findsNothing,
      );
    });

    testWidgets('database name trims surrounding whitespace', (
      WidgetTester tester,
    ) async {
      await openCreateDatabaseDialog(tester);

      await tester.enterText(find.byKey(nameField), '  abc  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.text('Database name is required.'), findsNothing);
      expect(
        find.text('Database name must be at least 3 characters.'),
        findsNothing,
      );
    });

    testWidgets('username reports length bounds with its label', (
      WidgetTester tester,
    ) async {
      await openConnectUserDialog(tester);

      await tester.enterText(find.byKey(usernameField), 'u' * 64);
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(
        find.text('Username must be 63 characters or fewer.'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(usernameField), 'ab');
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(
        find.text('Username must be at least 3 characters.'),
        findsOneWidget,
      );
    });

    testWidgets('username reports length before pattern', (
      WidgetTester tester,
    ) async {
      await openConnectUserDialog(tester);

      // Two characters AND a bad pattern: length must win on both sides.
      await tester.enterText(find.byKey(usernameField), 'A!');
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(
        find.text('Username must be at least 3 characters.'),
        findsOneWidget,
      );
    });

    testWidgets('username rejects leading digits', (WidgetTester tester) async {
      await openConnectUserDialog(tester);

      await tester.enterText(find.byKey(usernameField), '1abc');
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Username must start with a letter and use lowercase letters, numbers, or underscores.',
        ),
        findsOneWidget,
      );
    });

    test('name pattern message and both patterns pinned in source', () {
      // The name field's input formatter strips pattern-breaking input, so
      // the name pattern-failure message is unreachable through the UI: pin
      // the label + fragment + composition it is built from instead.
      final source = File(
        'lib/ui/project/workspace/database/database_tab_logic.dart',
      ).readAsStringSync();
      expect(source.contains("fieldLabel: 'Database name'"), isTrue);
      expect(
        source.contains(
          'may only use lowercase letters, numbers, or underscores.',
        ),
        isTrue,
      );
      expect(source.contains(r'$fieldLabel $patternHelp'), isTrue);
      expect(source.contains(r'^[a-z0-9_]+$'), isTrue);
      expect(source.contains(r'^[a-z][a-z0-9_]*$'), isTrue);
    });

    test('identifier bounds have one owner (shape pin)', () {
      final source = File(
        'lib/ui/project/workspace/database/database_tab_logic.dart',
      ).readAsStringSync();
      expect('value.length > 63'.allMatches(source).length, 1);
    });
  });
}
