import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// project workspace PostgreSQL databases and users.
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

  group('project workspace PostgreSQL databases and users', () {
    testWidgets('Database tab lets users select active database and user', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db', 'beta_db'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'alpha_user',
              'database': 'alpha_db',
              'access_mode': 'read_write',
            },
            <String, dynamic>{
              'username': 'beta_user',
              'database': 'beta_db',
              'access_mode': 'read_only',
              'host': 'postgres-primary.internal',
              'port': 5432,
            },
            <String, dynamic>{
              'username': 'zeta_reader',
              'database': 'beta_db',
              'access_mode': 'read_only',
              'host': 'postgres-reader.internal',
              'port': 6432,
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

      final selectedCard = find.byKey(const Key('database-selected-card'));
      final connectionCard = find.byKey(const Key('database-connection-card'));
      expect(
        find.descendant(
          of: selectedCard,
          matching: find.byKey(
            const Key('database-actions-select-database-dropdown'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('database-select-user-dropdown')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: selectedCard,
          matching: find.text('Select the database you want to work with'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: selectedCard,
          matching: find.text('Current selection'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: selectedCard,
          matching: find.text('Project databases'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: connectionCard,
          matching: find.byKey(const Key('database-select-database-dropdown')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: connectionCard, matching: find.text('alpha_db')),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: connectionCard, matching: find.text('alpha_user')),
        findsAtLeastNWidgets(1),
      );

      expect(
        find.byKey(const Key('database-resource-alpha_db')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('database-resource-beta_db')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('database-resource-beta_db')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: connectionCard, matching: find.text('beta_db')),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: connectionCard, matching: find.text('beta_user')),
        findsAtLeastNWidgets(1),
      );

      await tester.tap(find.byKey(const Key('database-select-user-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('zeta_reader').last);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: connectionCard, matching: find.text('zeta_reader')),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: connectionCard, matching: find.text('6432')),
        findsOneWidget,
      );
    });

    testWidgets(
      'Database connection target follows active database and user selection',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'beta_db',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'beta_user',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PASSWORD',
              value: 'pg-secret-123',
            ),
          ],
        );
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
              <String, dynamic>{
                'username': 'beta_user',
                'database': 'beta_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('database-actions-select-database-dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('beta_db').last);
        await tester.pumpAndSettle();

        final connectionCard = find.byKey(
          const Key('database-connection-card'),
        );
        expect(
          find.descendant(of: connectionCard, matching: find.text('beta_db')),
          findsAtLeastNWidgets(1),
        );
        expect(
          find.descendant(of: connectionCard, matching: find.text('beta_user')),
          findsAtLeastNWidgets(1),
        );

        expect(
          find.byKey(const Key('database-copy-connection-button')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Database backup card routes users to Backup tab', (
      WidgetTester tester,
    ) async {
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

      final databaseScroll = find
          .descendant(
            of: find.byKey(const Key('database-tab-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('database-open-backup-tab-button')),
        300,
        scrollable: databaseScroll,
      );
      await tester.ensureVisible(
        find.byKey(const Key('database-open-backup-tab-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('database-open-backup-tab-button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(find.text('Backups'), findsOneWidget);
    });

    testWidgets('Connect existing dialog uses discovered database picker', (
      WidgetTester tester,
    ) async {
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
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      final createUserButton = find.byKey(const Key('database-link-button'));
      await tester.ensureVisible(createUserButton);
      expect(
        tester.widget<OutlinedButton>(createUserButton).onPressed,
        isNotNull,
      );
      await tester.tap(createUserButton);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Create user for existing database'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('database-connect-existing-dropdown')),
        findsOneWidget,
      );
      expect(find.text('Database name'), findsNothing);
      expect(
        find.byKey(const Key('database-connect-existing-username-field')),
        findsOneWidget,
      );
    });

    testWidgets(
      'Connect existing dialog shows guidance when no databases exist',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>[],
            'users': <Map<String, dynamic>>[],
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        final createUserButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('database-link-button')),
        );
        expect(createUserButton.onPressed, isNotNull);
        createUserButton.onPressed!.call();
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('database-connect-existing-empty-state')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Create database dialog sanitizes name and validates input', (
      WidgetTester tester,
    ) async {
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
      await tester.tap(find.byKey(const Key('database-create-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.text('Database name is required.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('database-create-name-field')),
        'Bad-Name_01',
      );
      expect(
        textFieldValue(tester, const Key('database-create-name-field')),
        'badname_01',
      );
    });

    testWidgets(
      'PostgreSQL database credentials keep web app env rows user-managed',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        final envRepository = AppEnvironmentVariableRepository(database);
        await envRepository.replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'APP_ENV',
              value: 'production',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_HOST',
              value: 'stale-host',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PORT',
              value: '9999',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'alpha_db',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'alpha_user',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PASSWORD',
              value: 'old-password',
            ),
          ],
        );
        final projectNotifier = RecordingDatabaseWiringProjectNotifier(
          selectedProject,
        );
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
          database: database,
          overrides: [
            projectListProvider.overrideWith(() => projectNotifier),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        expect(find.text('DATABASE_HOST'), findsOneWidget);
        expect(find.text('stale-host'), findsNothing);
        expect(find.text('deploydash_postgres'), findsNothing);

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('database-add-postgres-webapp-button')),
          findsNothing,
        );
        expect(
          find.textContaining('Environment variables editor'),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(Tab, 'Web app'));
        await tester.pumpAndSettle();

        expect(find.text('DATABASE_HOST'), findsOneWidget);
        expect(find.text('stale-host'), findsNothing);
        expect(find.text('old-password'), findsNothing);

        final rows = await envRepository.listForProject(selectedProject.id);
        final valuesByKey = <String, String>{
          for (final row in rows) row.key: row.value,
        };
        expect(valuesByKey['DATABASE_HOST'], 'stale-host');
        expect(valuesByKey['DATABASE_PORT'], '9999');
        expect(valuesByKey['DATABASE_PASSWORD'], 'old-password');
      },
    );

    testWidgets(
      'Database users renders selected database cards without a data table',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
              <String, dynamic>{
                'username': 'beta_reader',
                'database': 'beta_db',
                'access_mode': 'read_only',
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();

        final usersCard = find.byKey(const Key('database-access-card'));
        expect(usersCard, findsOneWidget);
        await tester.ensureVisible(usersCard);
        await tester.pumpAndSettle();
        expect(find.byType(DataTable), findsNothing);
        final actionsCard = find.byKey(const Key('database-actions-card'));
        expect(
          find.descendant(
            of: usersCard,
            matching: find.byKey(const Key('database-link-button')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: actionsCard,
            matching: find.byKey(const Key('database-link-button')),
          ),
          findsNothing,
        );
        expect(find.text('alpha_user'), findsWidgets);
        expect(find.text('beta_reader'), findsNothing);
        expect(find.text('Can read data and manage tables'), findsOneWidget);
        expect(find.text('Can read data only'), findsNothing);
        expect(find.text('Reset password'), findsOneWidget);
        expect(find.text('Delete user'), findsOneWidget);
        expect(find.text('Create database user'), findsOneWidget);
      },
    );

    testWidgets('Database users prompts when no active database is selected', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db', 'beta_db'],
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
      await tester.tap(
        find.byKey(const Key('database-actions-select-database-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select a database').last);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Select a database to manage its users.'),
        findsOneWidget,
      );
      expect(find.text('alpha_user'), findsNothing);
    });

    testWidgets(
      'PostgreSQL create database keeps new credentials selected when only connection URI is returned',
      (WidgetTester tester) async {
        String? clipboardText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              final arguments = call.arguments as Map<dynamic, dynamic>;
              clipboardText = arguments['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
              <String, dynamic>{
                'username': 'beta_user',
                'database': 'beta_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'project_create_database': <String, dynamic>{
              'status': 'success',
              'msg': 'Database created.',
              'connection_uri':
                  'postgresql://beta_user:generated-secret@192.168.1.40:5432/beta_db',
            },
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

        expect(find.text('Not captured in this session'), findsOneWidget);

        await tester.tap(find.byKey(const Key('database-create-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('database-create-name-field')),
          'beta_db',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
        await tester.pumpAndSettle();

        expect(find.text('Database credentials'), findsOneWidget);
        expect(find.text('generated-secret'), findsWidgets);
        await tester.tap(find.widgetWithText(TextButton, 'Close').last);
        await tester.pumpAndSettle();

        expect(find.text('generated-secret'), findsOneWidget);
        expect(find.text('beta_db'), findsWidgets);
        expect(find.text('beta_user'), findsWidgets);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('database-copy-connection-button')),
              )
              .onPressed,
          isNotNull,
        );
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('database-copy-connection-button')),
            )
            .onPressed!
            .call();
        await tester.pump();
        expect(
          clipboardText,
          'postgresql://beta_user:generated-secret@host.docker.internal:5432/beta_db',
        );
        expect(
          find.byKey(const Key('database-add-postgres-webapp-button')),
          findsNothing,
        );
      },
    );

    testWidgets('PostgreSQL create database dialog updates permission help', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
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
      await tester.tap(find.byKey(const Key('database-create-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Can read data and manage tables').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Can read data only').last);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Can read data only. This user cannot create or change tables.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
    });

    testWidgets(
      'Connect existing dialog validates short and long usernames inline',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[],
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-link-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('database-connect-existing-username-field')),
          'ab',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create user').last);
        await tester.pumpAndSettle();
        expect(
          find.text('Username must be at least 3 characters.'),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('database-connect-existing-username-field')),
          'a' * 64,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create user').last);
        await tester.pumpAndSettle();
        expect(
          find.text('Username must be 63 characters or fewer.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Connect existing dialog updates database and permission pickers',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
            'users': <Map<String, dynamic>>[],
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-link-button')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('database-connect-existing-dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('beta_db').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Can read data and manage tables').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Can read data only').last);
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Can read data only. This user cannot create or change tables.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Password reset uses the selected database in its workflow payload',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
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
          operationResponses: const <String, Map<String, dynamic>>{
            'project_rotate_password': <String, dynamic>{
              'status': 'success',
              'password': 'new-secret',
            },
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Reset password'));
        await tester.pumpAndSettle();

        final rotateCall = sshService.callLog.lastWhere(
          (call) => call['operation_id'] == 'project_rotate_password',
        );
        final settings =
            (rotateCall['params'] as Map<String, dynamic>)['settings']
                as Map<String, dynamic>;
        expect(settings['database_name'], 'alpha_db');
      },
    );

    testWidgets(
      'Password reset sends logical names for a prefixed database user',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['dd_regs_v3_main'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'dd_regs_v3_main_user',
                'database': 'dd_regs_v3_main',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'project_rotate_password': <String, dynamic>{
              'status': 'success',
              'password': 'new-secret',
            },
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Reset password'));
        await tester.pumpAndSettle();

        final rotateCall = sshService.callLog.lastWhere(
          (call) => call['operation_id'] == 'project_rotate_password',
        );
        final settings =
            (rotateCall['params'] as Map<String, dynamic>)['settings']
                as Map<String, dynamic>;
        expect(settings['username'], 'main_user');
        expect(settings['database_name'], 'main');
      },
    );

    testWidgets(
      'Delete user sends logical names for a prefixed database user',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['dd_regs_v3_main'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'dd_regs_v3_main_user',
                'database': 'dd_regs_v3_main',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'project_delete_user': <String, dynamic>{'status': 'success'},
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Delete user'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
        await tester.pumpAndSettle();

        final deleteCall = sshService.callLog.lastWhere(
          (call) => call['operation_id'] == 'project_delete_user',
        );
        final settings =
            (deleteCall['params'] as Map<String, dynamic>)['settings']
                as Map<String, dynamic>;
        expect(settings['username'], 'main_user');
        expect(settings['database_name'], 'main');
      },
    );

    testWidgets(
      'Create user for existing database sends the logical database name',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['dd_regs_v3_main'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'dd_regs_v3_main_user',
                'database': 'dd_regs_v3_main',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'project_create_user': <String, dynamic>{'status': 'success'},
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        final createUserButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('database-link-button')),
        );
        createUserButton.onPressed!.call();
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('database-connect-existing-username-field')),
          'alpha_reader',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
        await tester.pumpAndSettle();

        final createCall = sshService.callLog.lastWhere(
          (call) => call['operation_id'] == 'project_create_user',
        );
        final settings =
            (createCall['params'] as Map<String, dynamic>)['settings']
                as Map<String, dynamic>;
        expect(settings['database_name'], 'main');
        expect(settings['username'], 'alpha_reader');
      },
    );

    testWidgets('Delete user dialog cancel does not run the workflow', (
      WidgetTester tester,
    ) async {
      final sshService = OperationOverrideDatabaseWorkflowSshService(
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
        operationResponses: const <String, Map<String, dynamic>>{},
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
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete user'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();

      expect(
        sshService.callLog.any(
          (call) =>
              call['workflow_id'] == 'postgres' &&
              call['operation_id'] == 'project_delete_user',
        ),
        isFalse,
      );
    });

    testWidgets('Database credentials dialog copy button copies the URI', (
      WidgetTester tester,
    ) async {
      final sshService = OperationOverrideDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'project_create_database': <String, dynamic>{
            'status': 'success',
            'connection_uri':
                'postgresql://alpha_user:secret@192.168.1.40:5432/alpha_db',
            'password': 'secret',
          },
        },
      );
      String? clipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final arguments = call.arguments as Map<dynamic, dynamic>;
              clipboardText = arguments['text'] as String?;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

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
      await tester.tap(find.byKey(const Key('database-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-create-name-field')),
        'alpha_db',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Copy').last);
      await tester.pumpAndSettle();

      expect(
        clipboardText,
        'postgresql://alpha_user:secret@host.docker.internal:5432/alpha_db',
      );
    });

    testWidgets(
      'PostgreSQL connection URI without a password still selects the returned user',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
              <String, dynamic>{
                'username': 'beta_user',
                'database': 'beta_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'project_create_database': <String, dynamic>{
              'status': 'success',
              'msg': 'Database created.',
              'connection_uri':
                  'postgresql://beta_user@192.168.1.40:5432/beta_db',
            },
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
        await tester.tap(find.byKey(const Key('database-create-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('database-create-name-field')),
          'beta_db',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Close').last);
        await tester.pumpAndSettle();

        expect(find.text('beta_user'), findsWidgets);
        expect(find.text('Not captured in this session'), findsOneWidget);
      },
    );

    testWidgets('Connect existing dialog validates username inline', (
      WidgetTester tester,
    ) async {
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
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      final createUserButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('database-link-button')),
      );
      expect(createUserButton.onPressed, isNotNull);
      createUserButton.onPressed!.call();
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(find.text('Username is required.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('database-connect-existing-username-field')),
        'Bad-User',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Username must start with a letter and use lowercase letters, numbers, or underscores.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Database user creation uses novice-friendly success wording', (
      WidgetTester tester,
    ) async {
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
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      final createUserButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('database-link-button')),
      );
      createUserButton.onPressed!.call();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-connect-existing-username-field')),
        'alpha_reader',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      expect(find.text('Database user created for alpha_db.'), findsOneWidget);
    });

    testWidgets(
      'Password reset shows scoped busy state for its database user',
      (WidgetTester tester) async {
        final sshService = DelayedOperationDatabaseWorkflowSshService(
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
          delayedOperationId: 'project_rotate_password',
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
        final databaseScroll = find
            .descendant(
              of: find.byKey(const Key('database-tab-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.widgetWithText(OutlinedButton, 'Reset password').first,
          300,
          scrollable: databaseScroll,
        );
        final resetButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Reset password').first,
        );
        expect(resetButton.onPressed, isNotNull);
        resetButton.onPressed!.call();
        await sshService.operationStarted.future;
        await tester.pump();

        expect(find.text('Resetting...'), findsOneWidget);

        sshService.releaseOperation.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('PostgreSQL mutations report the database event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final sshService = OperationOverrideDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'project_create_database': <String, dynamic>{
            'status': 'success',
            'msg': 'Database created.',
            'connection_uri':
                'postgresql://alpha_user:secret@192.168.1.40:5432/alpha_db',
            'password': 'secret',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-create-name-field')),
        'alpha_db',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
      await tester.pumpAndSettle();

      // The credentials dialog blocks the mutation tail until dismissed.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(analytics.databaseEvents, [
        (
          engine: DatabaseEngine.postgres,
          outcome: DataOperationOutcome.success,
        ),
      ]);
    });

    testWidgets('PostgreSQL mutation failures report the database event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final sshService = OperationOverrideDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'project_create_database': <String, dynamic>{
            'status': 'error',
            'msg': 'Database already exists.',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-create-name-field')),
        'alpha_db',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-text')), findsOneWidget);
      expect(analytics.databaseEvents, [
        (
          engine: DatabaseEngine.postgres,
          outcome: DataOperationOutcome.failure,
        ),
      ]);
    });

    testWidgets(
      'Database copy connection is disabled when selected DB has no user',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
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

        await tester.tap(
          find.byKey(const Key('database-actions-select-database-dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('beta_db').last);
        await tester.pumpAndSettle();

        final copyButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('database-copy-connection-button')),
        );
        expect(copyButton.onPressed, isNull);
        expect(
          find.byKey(const Key('database-selected-db-no-user-hint')),
          findsOneWidget,
        );
      },
    );
  }, skip: !sqliteAvailable);
}
