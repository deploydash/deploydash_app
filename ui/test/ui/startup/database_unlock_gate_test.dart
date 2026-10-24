import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/providers/pending_enrollment_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/ui/startup/database_unlock_gate.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/fake_analytics_service.dart';

class _FakeOpenFileSelectorPlatform extends FileSelectorPlatform {
  _FakeOpenFileSelectorPlatform(this.openFilePath);

  final String? openFilePath;
  int openFileCallCount = 0;
  List<XTypeGroup>? lastAcceptedTypeGroups;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? confirmButtonText,
    String? initialDirectory,
    bool lockParentWindow = false,
  }) async {
    openFileCallCount += 1;
    lastAcceptedTypeGroups = acceptedTypeGroups;
    final path = openFilePath;
    return path == null ? null : XFile(path);
  }
}

class _EnrollingServerNotifier extends ServerNotifier {
  _EnrollingServerNotifier(this.checkResult);

  final Map<String, dynamic> checkResult;

  @override
  Future<void> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
  }) async {
    state = state.copyWith(isLoading: false, result: checkResult);
  }

  @override
  Future<void> loadSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
  }) async {}
}

Map<String, dynamic> _passingCheckResult() {
  return <String, dynamic>{
    'status': 'success',
    'os': 'Ubuntu 24.04',
    'cpu': 'x86_64',
    'memory_mb': 8192,
    'disk_gb': 120,
    'compatibility': <String, dynamic>{
      'status': 'pass',
      'summary': 'Server meets add-server compatibility requirements.',
      'checks': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'os_ubuntu_24_04',
          'label': 'Operating system is Ubuntu 24.04.x',
          'passed': true,
          'message': 'OS requirement satisfied.',
        },
      ],
    },
  };
}

/// Drives the pre-enrollment wizard from the intro to review:
/// start, credentials, and a passing check. Tests open the modal and
/// submit it themselves.
Future<void> _driveToReviewScreen(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('server-name-field')),
    'Production web server',
  );
  await tester.enterText(
    find.byKey(const Key('server-host-field')),
    '203.0.113.10',
  );
  await tester.enterText(
    find.byKey(const Key('server-password-field')),
    'secret',
  );
  await tester.tap(find.byKey(const Key('server-check-button')));
  await tester.pumpAndSettle();
}

/// Taps Finish setup on the review screen and waits for the
/// create-password modal it opens.
Future<void> _openEnrollmentModal(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('server-save-button')));
  await tester.pumpAndSettle();
  expect(find.text('Create password and finish setup'), findsOneWidget);
}

void main() {
  setUp(() {
    debugOverrideDatabaseUnlockBackupFilePicker(null);
  });

  tearDown(() {
    debugOverrideDatabaseUnlockBackupFilePicker(null);
  });

  testWidgets('first-run controls expose stable Windows automation names', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (_) async => true,
        childBuilder: (_) => const SizedBox.shrink(),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );
    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);

    expect(
      tester
          .getSemantics(find.byKey(const Key('database-passphrase-field')))
          .label,
      contains('Passphrase'),
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const Key('database-confirm-passphrase-field')),
          )
          .label,
      contains('Confirm passphrase'),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('server-save-button'))).label,
      'Finish setup',
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('enrollment-submit-button')))
          .label,
      'Create password',
    );
    final passphrase = tester.getSemantics(
      find.byKey(const Key('database-passphrase-field')),
    );
    final confirmation = tester.getSemantics(
      find.byKey(const Key('database-confirm-passphrase-field')),
    );
    final submit = tester.getSemantics(
      find.byKey(const Key('server-save-button')),
    );
    final modalSubmit = tester.getSemantics(
      find.byKey(const Key('enrollment-submit-button')),
    );
    expect(passphrase.flagsCollection.isTextField, isTrue);
    expect(passphrase.flagsCollection.isObscured, isTrue);
    expect(confirmation.flagsCollection.isTextField, isTrue);
    expect(confirmation.flagsCollection.isObscured, isTrue);
    expect(submit.flagsCollection.isButton, isTrue);
    expect(modalSubmit.flagsCollection.isButton, isTrue);
    expect(find.bySemanticsLabel('Passphrase'), findsOneWidget);
    expect(find.bySemanticsLabel('Confirm passphrase'), findsOneWidget);
    expect(find.bySemanticsLabel('Finish setup'), findsOneWidget);
    expect(find.bySemanticsLabel('Create password'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('creates passphrase on first startup', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (passphrase) async => passphrase == 'topsecret',
        validatePassphrase: (passphrase) async => passphrase == 'topsecret',
        childBuilder: (passphrase) =>
            MaterialApp(home: Scaffold(body: Text('unlocked:$passphrase'))),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );

    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);

    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.enterText(
      find.byKey(const Key('database-confirm-passphrase-field')),
      'topsecret',
    );
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('unlocked:topsecret'), findsOneWidget);
  });

  testWidgets('enrollment carries the passphrase across the scope rebuild', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (passphrase) async => passphrase == 'topsecret',
        childBuilder: (passphrase) => ProviderScope(
          // Mirrors buildDeployDashProviderScope's inner scope without
          // mounting the shell: the gate nests it the same way.
          overrides: [
            initialDatabasePassphraseProvider.overrideWithValue(passphrase),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final held = ref.watch(databasePassphraseProvider);
                  final fresh = ref.watch(freshEnrollmentSessionProvider);
                  return Column(
                    children: [Text('passphrase:$held'), Text('fresh:$fresh')],
                  );
                },
              ),
            ),
          ),
        ),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );
    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);
    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.enterText(
      find.byKey(const Key('database-confirm-passphrase-field')),
      'topsecret',
    );
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();

    // The nested enrollment scope must carry the passphrase: without it
    // the holder builds null and the app tree opens the encrypted
    // database unencrypted, failing every read.
    expect(find.text('passphrase:topsecret'), findsOneWidget);
    // ... and it must mark the session as a fresh enrollment, so the
    // shell keeps the first-run wizard mounted while its first server's
    // setup is still pending.
    expect(find.text('fresh:true'), findsOneWidget);
  });

  testWidgets('create password keyboard flow advances then submits', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (passphrase) async => passphrase == 'topsecret',
        childBuilder: (passphrase) =>
            MaterialApp(home: Scaffold(body: Text('ready:$passphrase'))),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );
    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);

    EditableText editableFor(Key key) => tester.widget<EditableText>(
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText)),
    );

    expect(
      editableFor(const Key('database-passphrase-field')).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(
      editableFor(
        const Key('database-confirm-passphrase-field'),
      ).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const Key('database-confirm-passphrase-field')),
      'topsecret',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('ready:topsecret'), findsOneWidget);
  });

  testWidgets('shows create failure message when fresh database setup fails', (
    WidgetTester tester,
  ) async {
    // The modal is taller than the default surface: without room the
    // failure tile's Technical details row is not tappable.
    tester.view.physicalSize = const Size(1440, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (_) async => false,
        createFailureDetails: () =>
            'Bad state: encrypted database setup failed',
        childBuilder: (_) => const SizedBox.shrink(),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );

    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);

    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.enterText(
      find.byKey(const Key('database-confirm-passphrase-field')),
      'topsecret',
    );
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Couldn’t create the local encrypted database. Your password was not '
        'saved. Review the technical details and try again.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Technical details'));
    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    expect(
      find.text('Bad state: encrypted database setup failed'),
      findsOneWidget,
    );
  });

  testWidgets('requires matching passphrases during creation', (
    WidgetTester tester,
  ) async {
    var createCallCount = 0;

    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (passphrase) async {
          createCallCount += 1;
          return true;
        },
        childBuilder: (_) => const SizedBox.shrink(),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );

    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);

    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'alpha',
    );
    await tester.enterText(
      find.byKey(const Key('database-confirm-passphrase-field')),
      'beta',
    );
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Passphrases do not match.'), findsOneWidget);
    expect(createCallCount, 0);
  });

  testWidgets('unlocks existing encrypted database', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        validatePassphrase: (passphrase) async => passphrase == 'correct-horse',
        enforceBackupFormatVersion: (passphrase) async {},
        childBuilder: (passphrase) =>
            MaterialApp(home: Scaffold(body: Text('ready:$passphrase'))),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Unlock Deploy Dash'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'wrong',
    );
    await tester.tap(find.byKey(const Key('database-passphrase-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect passphrase.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'correct-horse',
    );
    await tester.tap(find.byKey(const Key('database-passphrase-submit')));
    await tester.pumpAndSettle();

    expect(find.text('ready:correct-horse'), findsOneWidget);
  });

  testWidgets('unlock blocks an unsupported restored backup format', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        validatePassphrase: (passphrase) async => passphrase == 'correct-horse',
        enforceBackupFormatVersion: (_) async {
          throw StateError('backup format is newer than this app');
        },
        childBuilder: (_) => const Text('unlocked'),
      ),
    );

    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'correct-horse',
    );
    await tester.tap(find.byKey(const Key('database-passphrase-submit')));
    await tester.pumpAndSettle();

    expect(find.text('unlocked'), findsNothing);
    expect(
      find.textContaining('Couldn’t restore that backup file.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('backup format is newer than this app'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('database-passphrase-submit')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('passphrase field submits unlock form on enter', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        validatePassphrase: (passphrase) async => passphrase == 'correct-horse',
        enforceBackupFormatVersion: (passphrase) async {},
        childBuilder: (passphrase) =>
            MaterialApp(home: Scaffold(body: Text('ready:$passphrase'))),
      ),
    );

    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'correct-horse',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('ready:correct-horse'), findsOneWidget);
  });

  testWidgets(
    'startup create mode exposes restore flow and returns to unlock',
    (WidgetTester tester) async {
      String? restoredPath;
      debugOverrideDatabaseUnlockBackupFilePicker(
        () async => '/tmp/deploydash_state_20260316.db',
      );

      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          restoreBackupFile:
              ({required sourcePath, overwriteExisting = false}) async {
                restoredPath = sourcePath;
                expect(overwriteExisting, isTrue);
                return File('/tmp/deploydash_state.db');
              },
          createPassphrase: (passphrase) async => passphrase == 'topsecret',
          validatePassphrase: (passphrase) async => passphrase == 'topsecret',
          enforceBackupFormatVersion: (passphrase) async {},
          childBuilder: (passphrase) =>
              MaterialApp(home: Scaffold(body: Text('unlocked:$passphrase'))),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('database-restore-launch-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('database-restore-launch-button')));
      await tester.pumpAndSettle();

      expect(find.text('Restore your app data'), findsOneWidget);
      await tester.tap(find.byKey(const Key('database-restore-browse-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('database-restore-path-field')),
            )
            .controller!
            .text,
        '/tmp/deploydash_state_20260316.db',
      );

      await tester.tap(find.byKey(const Key('database-restore-submit')));
      await tester.pumpAndSettle();

      expect(restoredPath, '/tmp/deploydash_state_20260316.db');
      expect(
        find.text('Backup restored. Enter your password to continue.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('database-passphrase-field')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.tap(find.byKey(const Key('database-passphrase-submit')));
      await tester.pumpAndSettle();

      expect(find.text('unlocked:topsecret'), findsOneWidget);
    },
  );

  testWidgets('fresh launch serves onboarding on the pre-enrollment scope', (
    WidgetTester tester,
  ) async {
    // No server seam: the real transient provider reads the host's
    // null-recovery SSH service, proving the production wiring builds.
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (_) async => true,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('server-onboarding-start-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('database-passphrase-field')), findsNothing);
  });

  testWidgets('restore from onboarding returns to onboarding', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (_) async => true,
        childBuilder: (_) => const SizedBox.shrink(),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    await tester.pumpAndSettle();
    expect(find.text('Restore your app data'), findsOneWidget);

    await tester.tap(find.byKey(const Key('database-restore-back-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('server-onboarding-start-button')),
      findsOneWidget,
    );
  });

  testWidgets(
    'enrollment carries the pending server across the scope rebuild',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (passphrase) async => passphrase == 'topsecret',
          childBuilder: (passphrase) =>
              MaterialApp(home: Scaffold(body: Text('enrolled:$passphrase'))),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );
      await tester.pumpAndSettle();
      await _driveToReviewScreen(tester);
      await _openEnrollmentModal(tester);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'topsecret',
      );
      await tester.tap(find.byKey(const Key('enrollment-submit-button')));
      await tester.pumpAndSettle();

      expect(find.text('enrolled:topsecret'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.text('enrolled:topsecret')),
      );
      final pending = container.read(pendingEnrollmentProvider);
      expect(pending, isNotNull);
      expect(pending!.draft.host, '203.0.113.10');
      expect(pending.draft.sshPassword, 'secret');
    },
  );

  testWidgets('restore from the intro unlocks with no stashed server', (
    WidgetTester tester,
  ) async {
    debugOverrideDatabaseUnlockBackupFilePicker(
      () async => '/tmp/deploydash_state_20260316.db',
    );
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        restoreBackupFile:
            ({required sourcePath, overwriteExisting = false}) async {
              return File('/tmp/deploydash_state.db');
            },
        createPassphrase: (passphrase) async => passphrase == 'topsecret',
        validatePassphrase: (passphrase) async => passphrase == 'topsecret',
        enforceBackupFormatVersion: (passphrase) async {},
        childBuilder: (passphrase) => ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: Text('unlocked:$passphrase')),
          ),
        ),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing is stashed before Finish; restoring from the intro installs
    // the file and unlocks it, still with no stashed server.
    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-browse-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-submit')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.tap(find.byKey(const Key('database-passphrase-submit')));
    await tester.pumpAndSettle();

    expect(find.text('unlocked:topsecret'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.text('unlocked:topsecret')),
    );
    expect(container.read(pendingEnrollmentProvider), isNull);
  });

  testWidgets('the restore entry leaves with the intro', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (_) async => true,
        childBuilder: (_) => const SizedBox.shrink(),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsOneWidget,
    );
    await _driveToReviewScreen(tester);
    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsNothing,
    );
  });

  testWidgets('fresh launch reports onboarding started exactly once', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (_) async => true,
          childBuilder: (_) => const SizedBox.shrink(),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );
      await tester.pumpAndSettle();
      expect(analytics.onboardingStartedCallCount, 1);

      // Navigating to restore and back reopens the wizard without
      // reporting a second launch.
      await tester.tap(find.byKey(const Key('database-restore-launch-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-restore-back-button')));
      await tester.pumpAndSettle();
      expect(analytics.onboardingStartedCallCount, 1);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('enrollment reports success', (WidgetTester tester) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (passphrase) async => passphrase == 'topsecret',
          childBuilder: (passphrase) =>
              MaterialApp(home: Scaffold(body: Text('enrolled:$passphrase'))),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );
      await tester.pumpAndSettle();
      await _driveToReviewScreen(tester);
      await _openEnrollmentModal(tester);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'topsecret',
      );
      await tester.tap(find.byKey(const Key('enrollment-submit-button')));
      await tester.pumpAndSettle();

      expect(find.text('enrolled:topsecret'), findsOneWidget);
      expect(analytics.enrollmentOutcomes, [DataOperationOutcome.success]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('enrollment reports failure', (WidgetTester tester) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (_) async => false,
          createFailureDetails: () => 'setup failed',
          childBuilder: (_) => const SizedBox.shrink(),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );
      await tester.pumpAndSettle();
      await _driveToReviewScreen(tester);
      await _openEnrollmentModal(tester);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'topsecret',
      );
      await tester.tap(find.byKey(const Key('enrollment-submit-button')));
      await tester.pumpAndSettle();

      expect(analytics.enrollmentOutcomes, [DataOperationOutcome.failure]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('enrollment validation silence reports nothing', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (_) async => true,
          childBuilder: (_) => const SizedBox.shrink(),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );
      await tester.pumpAndSettle();
      await _driveToReviewScreen(tester);
      await _openEnrollmentModal(tester);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'mismatch',
      );
      await tester.tap(find.byKey(const Key('enrollment-submit-button')));
      await tester.pumpAndSettle();

      expect(find.text('Passphrases do not match.'), findsOneWidget);
      expect(analytics.enrollmentOutcomes, isEmpty);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('restore flow surfaces restore failures', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        pickBackupFile: () async => '/tmp/missing.db',
        restoreBackupFile: ({required sourcePath, overwriteExisting = false}) {
          return Future<File>.error(StateError('backup file is invalid'));
        },
        createPassphrase: (_) async => false,
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-browse-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-submit')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Couldn’t restore that backup file.\nBad state: backup file is invalid',
      ),
      findsOneWidget,
    );
  });

  testWidgets('unlock mode exposes restore launch and back returns to unlock', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        pickBackupFile: () async => null,
        restoreBackupFile: ({required sourcePath, overwriteExisting = false}) {
          return Future<File>.error(StateError('should not restore'));
        },
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    await tester.pumpAndSettle();
    expect(find.text('Restore your app data'), findsOneWidget);

    await tester.tap(find.byKey(const Key('database-restore-back-button')));
    await tester.pumpAndSettle();
    expect(find.text('Unlock Deploy Dash'), findsOneWidget);
    expect(find.byKey(const Key('database-passphrase-field')), findsOneWidget);
  });

  testWidgets('restore submit requires selecting a backup file first', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        pickBackupFile: () async => null,
        restoreBackupFile: ({required sourcePath, overwriteExisting = false}) {
          return Future<File>.error(StateError('should not restore'));
        },
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text('Choose a downloaded backup file to restore.'),
      findsOneWidget,
    );
  });

  testWidgets('startup mode check failure falls back to unlock with error', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => throw StateError('db check failed'),
        pickBackupFile: () async => null,
        restoreBackupFile: ({required sourcePath, overwriteExisting = false}) {
          return Future<File>.error(StateError('should not restore'));
        },
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.text(
        'Couldn’t check the local app data. Try unlocking the app again.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('database-passphrase-field')), findsOneWidget);
    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsOneWidget,
    );
  });

  testWidgets('empty passphrase shows required validation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-passphrase-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a passphrase to continue.'), findsOneWidget);
  });

  testWidgets('visibility toggle updates both passphrase fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => false,
        createPassphrase: (_) async => false,
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
        preEnrollmentServerNotifier: () =>
            _EnrollingServerNotifier(_passingCheckResult()),
      ),
    );

    await tester.pumpAndSettle();
    await _driveToReviewScreen(tester);
    await _openEnrollmentModal(tester);

    bool isObscured(Key key) {
      return tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText;
    }

    expect(isObscured(const Key('database-passphrase-field')), isTrue);
    expect(isObscured(const Key('database-confirm-passphrase-field')), isTrue);

    await tester.tap(find.byKey(const Key('database-passphrase-visibility')));
    await tester.pumpAndSettle();

    expect(isObscured(const Key('database-passphrase-field')), isFalse);
    expect(isObscured(const Key('database-confirm-passphrase-field')), isFalse);
  });

  testWidgets('default restore picker uses db file filter', (
    WidgetTester tester,
  ) async {
    final originalSelector = FileSelectorPlatform.instance;
    final selector = _FakeOpenFileSelectorPlatform('/tmp/deploydash_state.db');
    FileSelectorPlatform.instance = selector;
    addTearDown(() => FileSelectorPlatform.instance = originalSelector);

    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('database-restore-browse-button')));
    await tester.pumpAndSettle();

    expect(selector.openFileCallCount, 1);
    expect(selector.lastAcceptedTypeGroups, isNotNull);
    expect(selector.lastAcceptedTypeGroups, hasLength(1));
    expect(selector.lastAcceptedTypeGroups!.single.label, contains('backup'));
    expect(selector.lastAcceptedTypeGroups!.single.extensions, ['db']);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('database-restore-path-field')),
          )
          .controller!
          .text,
      '/tmp/deploydash_state.db',
    );
  });

  testWidgets(
    'confirm field clears mismatch error and submits on enter after correction',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (passphrase) async => passphrase == 'topsecret',
          validatePassphrase: (passphrase) async => passphrase == 'topsecret',
          childBuilder: (passphrase) =>
              MaterialApp(home: Scaffold(body: Text('unlocked:$passphrase'))),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );

      await tester.pumpAndSettle();
      await _driveToReviewScreen(tester);
      await _openEnrollmentModal(tester);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'wrong',
      );
      await tester.tap(find.byKey(const Key('enrollment-submit-button')));
      await tester.pumpAndSettle();

      expect(find.text('Passphrases do not match.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'topsecret',
      );
      await tester.pumpAndSettle();
      expect(find.text('Passphrases do not match.'), findsNothing);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('unlocked:topsecret'), findsOneWidget);
    },
  );

  testWidgets('wrong passphrase reports one auth failure', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => true,
          validatePassphrase: (_) async => false,
          enforceBackupFormatVersion: (passphrase) async {},
          childBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'wrong',
      );
      await tester.tap(find.byKey(const Key('database-passphrase-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect passphrase.'), findsOneWidget);
      expect(analytics.unlockFailures, [UnlockFailureReason.authFailed]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('failed database creation reports one auth failure', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          createPassphrase: (_) async => false,
          createFailureDetails: () => 'setup failed',
          childBuilder: (_) => const SizedBox.shrink(),
          preEnrollmentServerNotifier: () =>
              _EnrollingServerNotifier(_passingCheckResult()),
        ),
      );
      await tester.pumpAndSettle();
      await _driveToReviewScreen(tester);
      await _openEnrollmentModal(tester);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'topsecret',
      );
      await tester.enterText(
        find.byKey(const Key('database-confirm-passphrase-field')),
        'topsecret',
      );
      await tester.tap(find.byKey(const Key('enrollment-submit-button')));
      await tester.pumpAndSettle();

      expect(analytics.unlockFailures, [UnlockFailureReason.authFailed]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('unreadable local data reports one missing-database failure', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async =>
              throw const FileSystemException('data directory unreadable'),
          validatePassphrase: (_) async => false,
          childBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Couldn’t check the local app data. Try unlocking the app again.',
        ),
        findsOneWidget,
      );
      expect(analytics.unlockFailures, [UnlockFailureReason.dbMissing]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('missing restore file reports one missing-database failure', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          pickBackupFile: () async => '/tmp/missing.db',
          restoreBackupFile:
              ({required sourcePath, overwriteExisting = false}) {
                return Future<File>.error(
                  StateError('Backup file does not exist.'),
                );
              },
          createPassphrase: (_) async => false,
          validatePassphrase: (_) async => false,
          childBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('database-restore-launch-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-restore-browse-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-restore-submit')));
      await tester.pumpAndSettle();

      expect(analytics.unlockFailures, [UnlockFailureReason.dbMissing]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('unreadable restore file reports one missing-database failure', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => false,
          pickBackupFile: () async => '/tmp/unreadable.db',
          restoreBackupFile:
              ({required sourcePath, overwriteExisting = false}) {
                return Future<File>.error(
                  const FileSystemException('backup file unreadable'),
                );
              },
          createPassphrase: (_) async => false,
          validatePassphrase: (_) async => false,
          childBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('database-restore-launch-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-restore-browse-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-restore-submit')));
      await tester.pumpAndSettle();

      expect(analytics.unlockFailures, [UnlockFailureReason.dbMissing]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('newer restore format reports one corrupt-database failure', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => true,
          validatePassphrase: (passphrase) async => passphrase == 'correct',
          enforceBackupFormatVersion: (_) async {
            throw StateError('backup format is newer than this app');
          },
          childBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'correct',
      );
      await tester.tap(find.byKey(const Key('database-passphrase-submit')));
      await tester.pumpAndSettle();

      expect(analytics.unlockFailures, [UnlockFailureReason.dbCorrupt]);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('successful unlock and form validation report nothing', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(analytics);
    try {
      await tester.pumpWidget(
        DatabaseUnlockGate(
          databaseExists: () async => true,
          validatePassphrase: (passphrase) async => passphrase == 'correct',
          enforceBackupFormatVersion: (passphrase) async {},
          childBuilder: (passphrase) =>
              MaterialApp(home: Scaffold(body: Text('ready:$passphrase'))),
        ),
      );
      await tester.pumpAndSettle();

      // Form validation is not an attempt: empty submit reports nothing.
      await tester.tap(find.byKey(const Key('database-passphrase-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a passphrase to continue.'), findsOneWidget);
      expect(analytics.unlockFailures, isEmpty);

      await tester.enterText(
        find.byKey(const Key('database-passphrase-field')),
        'correct',
      );
      await tester.tap(find.byKey(const Key('database-passphrase-submit')));
      await tester.pumpAndSettle();

      expect(find.text('ready:correct'), findsOneWidget);
      expect(analytics.unlockFailures, isEmpty);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  testWidgets('unlock visibility toggle reveals the passphrase field', (
    tester,
  ) async {
    await tester.pumpWidget(
      DatabaseUnlockGate(
        databaseExists: () async => true,
        validatePassphrase: (_) async => false,
        childBuilder: (_) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    bool isObscured() {
      return tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('database-passphrase-field')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText;
    }

    expect(isObscured(), isTrue);
    await tester.tap(find.byKey(const Key('database-passphrase-visibility')));
    await tester.pumpAndSettle();
    expect(isObscured(), isFalse);
  });
}
