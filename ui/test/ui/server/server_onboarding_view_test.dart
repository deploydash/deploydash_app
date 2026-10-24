import 'dart:async';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ui/providers/pending_enrollment_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/providers/telemetry_settings_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/managed_ssh_key_service.dart';
import 'package:ui/ui/server/server_onboarding_view.dart';
import 'package:ui/ui/system/app_forms.dart';
import 'package:ui/ui/system/app_window_title.dart';

import '../../_support/fake_analytics_service.dart';

class _FakeServerNotifier extends ServerNotifier {
  _FakeServerNotifier({
    this.checkResult,
    this.checkError,
    this.setupResult,
    this.setupError,
    this.setupErrorPayload,
    this.setupCompleter,
    this.planGate,
    this.setupEvents = const <Map<String, dynamic>>[],
    this.plannedActions = const <Map<String, dynamic>>[],
    this.refreshHostKeyResult = true,
  });

  final Map<String, dynamic>? checkResult;
  final String? checkError;
  // Mutable so a test can fail one setup run and succeed the next, proving
  // the retry carries the next attempt number.
  Map<String, dynamic>? setupResult;
  String? setupError;
  Map<String, dynamic>? setupErrorPayload;
  final Completer<void>? setupCompleter;

  /// Holds [loadSetupPlan] open so a test can observe the window between a
  /// finished check and the navigation it triggers.
  final Completer<void>? planGate;
  final List<Map<String, dynamic>> setupEvents;
  final List<Map<String, dynamic>> plannedActions;
  final bool refreshHostKeyResult;

  int checkCalls = 0;
  int setupCalls = 0;
  int planCalls = 0;
  int refreshHostKeyCalls = 0;
  String? lastCheckPrivateKey;
  String? lastSetupPrivateKey;
  String? lastSetupPassword;

  @override
  ServerState build() => ServerState();

  @override
  Future<void> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
  }) async {
    checkCalls += 1;
    lastCheckPrivateKey = privateKey;
    state = state.copyWith(
      isLoading: false,
      result: checkResult,
      error: checkError,
      taskType: ServerTaskType.verification,
    );
  }

  @override
  Future<void> loadSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
  }) async {
    planCalls += 1;
    final planGate = this.planGate;
    if (planGate != null) {
      await planGate.future;
    }
    state = state.copyWith(setupActions: plannedActions);
  }

  @override
  Future<bool> refreshServerHostKey({
    required String host,
    int port = 22,
    required String username,
  }) async {
    refreshHostKeyCalls += 1;
    state = state.copyWith(
      isLoading: false,
      error: refreshHostKeyResult ? null : 'Unable to refresh host key',
      taskType: ServerTaskType.verification,
    );
    return refreshHostKeyResult;
  }

  @override
  Future<void> setupServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Map<String, dynamic>? managedConnection,
    List<String>? parts,
    Map<String, dynamic>? settings,
    bool dryRun = false,
  }) async {
    setupCalls += 1;
    state = state.copyWith(
      isLoading: true,
      error: null,
      errorPayload: null,
      setupResult: null,
      events: setupEvents,
      taskType: ServerTaskType.setup,
    );
    if (setupCompleter != null) {
      await setupCompleter!.future;
    }
    lastSetupPrivateKey = privateKey;
    lastSetupPassword = password;
    state = state.copyWith(
      isLoading: false,
      setupResult: setupResult,
      error: setupError,
      errorPayload: setupErrorPayload,
      taskType: ServerTaskType.setup,
    );
  }

  @override
  void reset() {
    state = ServerState();
  }
}

class _RecordingTelemetrySettingsNotifier extends TelemetrySettingsNotifier {
  int setEnabledCalls = 0;
  bool? lastEnabled;

  @override
  Future<void> setEnabled(bool enabled) async {
    setEnabledCalls += 1;
    lastEnabled = enabled;
    state = TelemetrySettingsState(enabled: enabled, homeNag: state.homeNag);
  }
}

class _FakeManagedSshKeyService extends ManagedSshKeyService {
  @override
  Future<ManagedSshKeyPair> createKeyPair({required String identifier}) async {
    return const ManagedSshKeyPair(
      privateKey: 'PRIVATE KEY',
      publicKey: 'ssh-ed25519 AAAATESTKEY deploydash-managed',
    );
  }
}

class _FixedCatalogNotifier extends ServerCatalogNotifier {
  _FixedCatalogNotifier(this.fixed);

  final ServerCatalogState fixed;

  @override
  ServerCatalogState build() => fixed;
}

Future<void> _pumpOnboarding(
  WidgetTester tester, {
  required _FakeServerNotifier serverNotifier,
  bool firstRun = false,
  String? initialStep,
  FakeAnalyticsService? analyticsService,
  TelemetrySettingsNotifier Function()? telemetrySettingsFactory,
  Future<void> Function({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  })?
  onCompleteServiceSelection,
  Future<Server> Function(ServerDraft draft, Map<String, dynamic> checkResult)?
  onSavePendingServer,
  Future<Server> Function({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  })?
  onUpdatePendingServer,
  Future<void> Function({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  })?
  onAdoptManagedIdentity,
  String? retryServerId,
  PendingEnrollment? pendingEnrollment,
  Future<EnrollmentResult> Function(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
    String passphrase,
  )?
  onEnrollmentRequired,
  VoidCallback? onRestoreRequest,
  ServerCatalogState? catalogState,
  Future<Map<String, dynamic>?> Function(Server)? resolvePayload,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverProvider.overrideWith(() => serverNotifier),
        managedSshKeyServiceProvider.overrideWithValue(
          _FakeManagedSshKeyService(),
        ),
        if (analyticsService != null)
          appAnalyticsServiceProvider.overrideWithValue(analyticsService),
        if (telemetrySettingsFactory != null)
          telemetrySettingsProvider.overrideWith(telemetrySettingsFactory),
        if (catalogState != null)
          serverCatalogProvider.overrideWith(
            () => _FixedCatalogNotifier(catalogState),
          ),
        if (resolvePayload != null)
          serverConnectionPayloadResolverProvider.overrideWithValue(
            resolvePayload,
          ),
        if (pendingEnrollment != null)
          pendingEnrollmentProvider.overrideWith(
            () => PendingEnrollmentNotifier(pendingEnrollment),
          ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ServerOnboardingView(
            firstRun: firstRun,
            initialStep: initialStep,
            retryServerId: retryServerId,
            pendingEnrollment: pendingEnrollment,
            onEnrollmentRequired: onEnrollmentRequired,
            onRestoreRequest: onRestoreRequest,
            onSavePendingServer:
                onSavePendingServer ??
                (draft, result) async => _pendingServer(),
            onUpdatePendingServer:
                onUpdatePendingServer ??
                ({
                  required serverId,
                  required draft,
                  required checkResult,
                }) async => _pendingServer(),
            onAdoptManagedIdentity:
                onAdoptManagedIdentity ??
                ({
                  required serverId,
                  required sshUser,
                  required authMethod,
                  privateKey,
                  publicKey,
                  managedUserPassword,
                }) async {},
            onCompleteServiceSelection: onCompleteServiceSelection,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

/// Hides its child on demand while the ProviderScope stays alive, modelling
/// how production removes the wizard (navigation) rather than tearing down
/// the whole scope. Lets abandon tests unmount the view deterministically.
class _WizardShell extends StatefulWidget {
  const _WizardShell({required this.child});

  final Widget child;

  @override
  State<_WizardShell> createState() => _WizardShellState();
}

class _WizardShellState extends State<_WizardShell> {
  bool _visible = true;

  void hide() => setState(() => _visible = false);

  @override
  Widget build(BuildContext context) {
    return _visible ? widget.child : const SizedBox();
  }
}

Future<_WizardShellState> _pumpWizardShell(
  WidgetTester tester, {
  required _FakeServerNotifier serverNotifier,
  required FakeAnalyticsService analyticsService,
  bool firstRun = false,
  String? retryServerId,
  ServerCatalogState? catalogState,
  Future<Map<String, dynamic>?> Function(Server)? resolvePayload,
  Future<Server> Function(ServerDraft draft, Map<String, dynamic> checkResult)?
  onSavePendingServer,
  Future<Server> Function({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  })?
  onUpdatePendingServer,
  Future<void> Function({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  })?
  onAdoptManagedIdentity,
  Future<void> Function({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  })?
  onCompleteServiceSelection,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverProvider.overrideWith(() => serverNotifier),
        managedSshKeyServiceProvider.overrideWithValue(
          _FakeManagedSshKeyService(),
        ),
        appAnalyticsServiceProvider.overrideWithValue(analyticsService),
        if (catalogState != null)
          serverCatalogProvider.overrideWith(
            () => _FixedCatalogNotifier(catalogState),
          ),
        if (resolvePayload != null)
          serverConnectionPayloadResolverProvider.overrideWithValue(
            resolvePayload,
          ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: _WizardShell(
            child: ServerOnboardingView(
              firstRun: firstRun,
              retryServerId: retryServerId,
              onSavePendingServer:
                  onSavePendingServer ??
                  (draft, result) async => _pendingServer(),
              onUpdatePendingServer:
                  onUpdatePendingServer ??
                  ({
                    required serverId,
                    required draft,
                    required checkResult,
                  }) async => _pendingServer(),
              onAdoptManagedIdentity:
                  onAdoptManagedIdentity ??
                  ({
                    required serverId,
                    required sshUser,
                    required authMethod,
                    privateKey,
                    publicKey,
                    managedUserPassword,
                  }) async {},
              onCompleteServiceSelection: onCompleteServiceSelection,
            ),
          ),
        ),
      ),
    ),
  );
  // A single pump, not settle: retry-mode tests gate the credential resolve
  // on a completer they complete after hiding the shell, and settle would
  // wait on that pending future forever. Callers settle after interacting.
  await tester.pump();
  return tester.state<_WizardShellState>(find.byType(_WizardShell));
}

Future<void> _fillCredentialForm(WidgetTester tester) async {
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
}

Server _pendingServer() {
  return Server(
    id: 'server-pending-1',
    name: 'Production web server',
    host: '203.0.113.10',
    port: 22,
    sshUser: 'root',
    authMethod: ServerAuthMethod.password,
  );
}

Map<String, dynamic> _passingCompatibility() {
  return <String, dynamic>{
    'status': 'pass',
    'summary': 'Server meets add-server compatibility requirements.',
    'checks': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'os_ubuntu_24_04',
        'label': 'Operating system is Ubuntu 24.04.x',
        'passed': true,
        'message': 'OS requirement satisfied.',
      },
      <String, dynamic>{
        'id': 'arch_x86_64',
        'label': 'CPU architecture is 64-bit x86',
        'passed': true,
        'message': 'CPU architecture requirement satisfied.',
      },
      <String, dynamic>{
        'id': 'existing_admin_keys',
        'label': 'Deploy Dash adds 1 SSH key',
        'passed': true,
        'message': 'ubuntu already has 2 SSH keys — they stay untouched.',
        'actual': 'SHA256:aaa\nSHA256:bbb',
      },
    ],
    'failed_checks': <Map<String, dynamic>>[],
  };
}

Map<String, dynamic> _failingCompatibility() {
  return <String, dynamic>{
    'status': 'fail',
    'summary':
        '1 compatibility check(s) failed. Resolve them before adding this server.',
    'checks': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'docker_absent',
        'label': 'Docker not already installed',
        'passed': false,
        'message': 'Docker appears to already be installed.',
      },
    ],
    'failed_checks': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'docker_absent',
        'label': 'Docker not already installed',
        'passed': false,
      },
    ],
  };
}

Map<String, dynamic> _failingReachabilityCompatibility() {
  return <String, dynamic>{
    'status': 'fail',
    'summary':
        '1 compatibility check(s) failed. Resolve them before adding this server.',
    'checks': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'docker_package_repository_reachable',
        'label': 'Docker package repository is reachable',
        'passed': false,
        'expected':
            'An HTTPS response below 500 from the Docker package repository.',
        'actual':
            'URLError: <urlopen error [Errno 101] Network is unreachable>',
        'message':
            'Setup would fail while installing Docker because the Docker package repository was not reachable.',
      },
    ],
    'failed_checks': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'docker_package_repository_reachable',
        'label': 'Docker package repository is reachable',
        'passed': false,
      },
    ],
  };
}

Map<String, dynamic> _successfulCheckResult({
  Map<String, dynamic>? compatibility,
}) {
  return <String, dynamic>{
    'status': 'success',
    'os': 'Ubuntu 24.04',
    'cpu': 'x86_64',
    'memory_mb': 8192,
    'disk_gb': 120,
    'compatibility': compatibility ?? _passingCompatibility(),
  };
}

void main() {
  testWidgets('connection controls expose stable Windows automation names', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    expect(
      tester
          .getSemantics(find.byKey(const Key('server-onboarding-start-button')))
          .label,
      'Get started',
    );
    await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
    await tester.pumpAndSettle();

    for (final entry in <Key, String>{
      const Key('server-name-field'): 'Server name',
      const Key('server-host-field'): 'Server address',
      const Key('server-user-field'): 'Username',
      const Key('server-password-field'): 'Password',
    }.entries) {
      expect(
        tester.getSemantics(find.byKey(entry.key)).label,
        contains(entry.value),
      );
    }
    expect(
      tester.getSemantics(find.byKey(const Key('server-check-button'))).label,
      'Check connection',
    );
    for (final key in <Key>[
      const Key('server-name-field'),
      const Key('server-host-field'),
      const Key('server-user-field'),
      const Key('server-password-field'),
    ]) {
      expect(
        tester.getSemantics(find.byKey(key)).flagsCollection.isTextField,
        isTrue,
      );
    }
    expect(
      tester
          .getSemantics(find.byKey(const Key('server-password-field')))
          .flagsCollection
          .isObscured,
      isTrue,
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('server-check-button')))
          .flagsCollection
          .isButton,
      isTrue,
    );
    expect(find.text('Password'), findsWidgets);
    expect(find.text('SSH key'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('first run starts on intro and can move to credentials', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    expect(find.text('Connect to your server'), findsOneWidget);
    await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
    await tester.pumpAndSettle();

    expect(find.text('Server details'), findsOneWidget);
  });

  testWidgets('the intro renders as a centered first-run screen', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    // The first screen names the product and centers its content like
    // the restore screen, instead of sitting in a workspace card.
    expect(
      find.byKey(const Key('server-onboarding-intro-flow')),
      findsOneWidget,
    );
    expect(find.text('Deploy Dash'), findsOneWidget);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(
      find.byKey(const Key('server-onboarding-start-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('server-onboarding-intro-flow')), findsNothing);
  });

  testWidgets('the intro offers restore only while it is showing', (
    tester,
  ) async {
    var restoreRequests = 0;
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      firstRun: true,
      onRestoreRequest: () {
        restoreRequests += 1;
      },
    );

    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('database-restore-launch-button')));
    expect(restoreRequests, 1);

    // Leaving the intro takes the restore entry with it: later steps
    // never offer it.
    await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsNothing,
    );
  });

  testWidgets('the intro hides restore without a host callback', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    // Post-unlock openings pass no restore callback: no database needs
    // restoring once one is unlocked.
    expect(
      find.byKey(const Key('database-restore-launch-button')),
      findsNothing,
    );
  });

  testWidgets('the credentials step renders as a centered screen', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
    await tester.pumpAndSettle();

    // The second screen uses the same centered focused flow as the
    // first, with its fields and actions unchanged inside it.
    expect(find.byKey(const Key('server-credentials-flow')), findsOneWidget);
    expect(find.text('Server details'), findsOneWidget);
    expect(find.byKey(const Key('server-name-field')), findsOneWidget);
    expect(find.byKey(const Key('server-check-button')), findsOneWidget);
  });

  testWidgets('the review step renders as a centered screen', (tester) async {
    final notifier = _FakeServerNotifier(checkResult: _successfulCheckResult());
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    await tester.tap(find.byKey(const Key('server-onboarding-start-button')));
    await tester.pumpAndSettle();
    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    // The third screen uses the same centered focused flow, with its
    // actions pinned to the footer.
    expect(find.byKey(const Key('server-review-flow')), findsOneWidget);
    expect(find.text('Review server details'), findsOneWidget);
    expect(find.byKey(const Key('server-save-button')), findsOneWidget);
    expect(
      find.byKey(const Key('server-confirmation-back-button')),
      findsOneWidget,
    );
  });

  testWidgets('keyboard focus advances through password connection flow', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(checkResult: _successfulCheckResult());
    await _pumpOnboarding(tester, serverNotifier: notifier, firstRun: true);

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('server-onboarding-start-button')),
          )
          .autofocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    EditableText editableFor(Key key) => tester.widget<EditableText>(
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText)),
    );

    expect(
      editableFor(const Key('server-name-field')).focusNode.hasFocus,
      isTrue,
    );
    for (final entry in <(Key, String)>[
      (const Key('server-name-field'), 'Production web server'),
      (const Key('server-host-field'), '203.0.113.10'),
      (const Key('server-port-field'), '22'),
      (const Key('server-user-field'), 'ubuntu'),
    ]) {
      await tester.enterText(find.byKey(entry.$1), entry.$2);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
    }
    expect(
      editableFor(const Key('server-password-field')).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const Key('server-password-field')),
      'secret',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(notifier.checkCalls, 1);
    expect(find.text('Review server details'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('server-save-button')))
          .autofocus,
      isTrue,
    );
  });

  testWidgets('SSH key import stays readable on compact onboarding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notifier = _FakeServerNotifier();
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await tester.tap(find.text('SSH key'));
    await tester.pumpAndSettle();

    final keyField = find.byKey(const Key('server-key-path-field'));
    final importButton = find.byKey(const Key('server-key-picker-button'));
    expect(keyField, findsOneWidget);
    expect(importButton, findsOneWidget);
    expect(tester.widget<AppTextFormField>(keyField).helperMaxLines, 3);
    expect(
      tester.getBottomLeft(keyField).dy,
      lessThan(tester.getTopLeft(importButton).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'connect success moves to confirmation and save reaches services',
    (tester) async {
      var saved = false;
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
        setupResult: const <String, dynamic>{'status': 'success'},
        plannedActions: const <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'action1',
            'label': 'Install Docker',
            'description': 'Install runtime',
            'part': 'part1',
          },
        ],
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              saved = true;
            },
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();

      expect(notifier.checkCalls, 1);
      expect(notifier.planCalls, 1);
      expect(find.text('Review server details'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.byKey(const Key('server-save-button')))
            .flagsCollection
            .isButton,
        isTrue,
      );
      expect(find.bySemanticsLabel('Finish setup'), findsOneWidget);
      expect(
        find.byKey(const Key('server-setup-plan-expansion')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('setup-actions-part1')), findsNothing);
      // Finish stays pinned in the footer, on-screen without scrolling
      // no matter how far the details run.
      final surfaceHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(
        tester.getRect(find.byKey(const Key('server-save-button'))).bottom,
        lessThanOrEqualTo(surfaceHeight),
      );

      await tester.ensureVisible(
        find.byKey(const Key('server-setup-plan-expansion')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-setup-plan-expansion')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setup-actions-part1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 1);
      expect(saved, isTrue);
      expect(find.text('Choose services'), findsOneWidget);
      expect(find.bySemanticsLabel('Continue'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('services-selection-continue-button')),
            )
            .autofocus,
        isTrue,
      );
    },
  );

  testWidgets('managed handoff carries the setup managed password', (
    tester,
  ) async {
    String? handoffPassword;
    String? handoffKey;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{
        'status': 'success',
        'managed_user_password': 'managed-secret',
      },
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onAdoptManagedIdentity:
          ({
            required serverId,
            required sshUser,
            required authMethod,
            privateKey,
            publicKey,
            managedUserPassword,
          }) async {
            handoffPassword = managedUserPassword;
            handoffKey = privateKey;
          },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(notifier.setupCalls, 1);
    expect(handoffPassword, 'managed-secret');
    expect(handoffKey, 'PRIVATE KEY');
  });

  testWidgets('managed handoff omits the managed password when absent', (
    tester,
  ) async {
    var handoffRan = false;
    String? handoffPassword = 'unset';
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onAdoptManagedIdentity:
          ({
            required serverId,
            required sshUser,
            required authMethod,
            privateKey,
            publicKey,
            managedUserPassword,
          }) async {
            handoffRan = true;
            handoffPassword = managedUserPassword;
          },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    // Bootstrapping as the managed user generates no password, so setup
    // returns none and the handoff carries none.
    expect(notifier.setupCalls, 1);
    expect(handoffRan, isTrue);
    expect(handoffPassword, isNull);
  });

  testWidgets(
    'pending save runs before provisioning with the bootstrap draft',
    (tester) async {
      ServerDraft? pendingDraft;
      var handoffServerId = 'unset';
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        onSavePendingServer: (draft, result) async {
          // Provisioning must not have started when the pending save runs.
          expect(notifier.setupCalls, 0);
          pendingDraft = draft;
          return _pendingServer();
        },
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              handoffServerId = serverId;
            },
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();

      expect(pendingDraft, isNotNull);
      expect(pendingDraft!.sshUser, 'ubuntu');
      // The bootstrap password is carried to the pending save so a retry
      // after a crash can still reach the machine.
      expect(pendingDraft!.sshPassword, 'secret');
      expect(notifier.setupCalls, 1);
      expect(handoffServerId, 'server-pending-1');
      expect(find.text('Choose services'), findsOneWidget);
    },
  );

  testWidgets('failed setup keeps the pending record without handoff', (
    tester,
  ) async {
    var pendingSaves = 0;
    var handoffs = 0;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onSavePendingServer: (draft, result) async {
        pendingSaves += 1;
        return _pendingServer();
      },
      onAdoptManagedIdentity:
          ({
            required serverId,
            required sshUser,
            required authMethod,
            privateKey,
            publicKey,
            managedUserPassword,
          }) async {
            handoffs += 1;
          },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(pendingSaves, 1);
    expect(notifier.setupCalls, 1);
    expect(handoffs, 0);
    expect(find.text('Setup needs attention'), findsOneWidget);
    expect(find.text('Choose services'), findsNothing);
  });

  testWidgets('failed setup retitles the window so automation fails fast', (
    tester,
  ) async {
    final titles = <String>[];
    debugOverrideAppWindowTitleSetter((title) async => titles.add(title));
    addTearDown(() => debugOverrideAppWindowTitleSetter(null));
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onSavePendingServer: (draft, result) async => _pendingServer(),
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Setup needs attention'), findsOneWidget);
    expect(titles, contains('Deploy Dash - Setup needs attention'));
  });

  testWidgets('failed setup runs report the incomplete run with its attempt', (
    tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      analyticsService: analytics,
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-setup-retry-button')));
    await tester.pumpAndSettle();

    expect(analytics.setupIncompleteAttempts, [1, 2]);
  });

  testWidgets(
    'handoff failure after success still reports the incomplete run',
    (tester) async {
      final analytics = FakeAnalyticsService();
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        analyticsService: analytics,
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              throw StateError('handoff write failed');
            },
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();

      // The run succeeded but the record never adopted: still incomplete.
      expect(analytics.setupIncompleteAttempts, [1]);
      expect(find.text('Setup needs attention'), findsOneWidget);
    },
  );

  testWidgets('retry after failed setup updates the pending record in place', (
    tester,
  ) async {
    var pendingSaves = 0;
    var pendingUpdates = 0;
    var updatedServerId = 'unset';
    var handoffs = 0;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onSavePendingServer: (draft, result) async {
        pendingSaves += 1;
        return _pendingServer();
      },
      onUpdatePendingServer:
          ({required serverId, required draft, required checkResult}) async {
            pendingUpdates += 1;
            updatedServerId = serverId;
            return _pendingServer();
          },
      onAdoptManagedIdentity:
          ({
            required serverId,
            required sshUser,
            required authMethod,
            privateKey,
            publicKey,
            managedUserPassword,
          }) async {
            handoffs += 1;
          },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    // The retry provisions the same record instead of saving a second one.
    notifier.setupResult = const <String, dynamic>{'status': 'success'};
    notifier.setupError = null;
    await tester.tap(find.byKey(const Key('server-setup-retry-button')));
    await tester.pumpAndSettle();

    expect(pendingSaves, 1);
    expect(pendingUpdates, 1);
    expect(updatedServerId, 'server-pending-1');
    expect(notifier.setupCalls, 2);
    expect(handoffs, 1);
    expect(find.text('Choose services'), findsOneWidget);
  });

  testWidgets('credential edits after failed setup update the pending record', (
    tester,
  ) async {
    var pendingSaves = 0;
    ServerDraft? updatedDraft;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onSavePendingServer: (draft, result) async {
        pendingSaves += 1;
        return _pendingServer();
      },
      onUpdatePendingServer:
          ({required serverId, required draft, required checkResult}) async {
            updatedDraft = draft;
            return _pendingServer();
          },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('server-setup-back-to-review-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-confirmation-back-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('server-host-field')),
      '203.0.113.99',
    );
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(pendingSaves, 1);
    expect(updatedDraft, isNotNull);
    expect(updatedDraft!.host, '203.0.113.99');
    expect(notifier.setupCalls, 2);
  });

  testWidgets('finish setup opens the create-password modal', (tester) async {
    var pendingSaves = 0;
    var handoffs = 0;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        handoffs += 1;
        return const EnrollmentResult(enrolled: true);
      },
      onSavePendingServer: (draft, result) async {
        pendingSaves += 1;
        return _pendingServer();
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    // The review carries no passphrase fields: Finish only opens the
    // modal, and nothing is saved, handed off, or provisioned before the
    // modal's own action runs.
    expect(find.text('Protect this app'), findsNothing);
    expect(find.byKey(const Key('database-passphrase-field')), findsNothing);
    expect(find.text('Create password and finish setup'), findsNothing);
    expect(find.byKey(const Key('server-save-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Create password and finish setup'), findsOneWidget);
    expect(find.byKey(const Key('database-passphrase-field')), findsOneWidget);
    expect(
      find.byKey(const Key('database-confirm-passphrase-field')),
      findsOneWidget,
    );
    expect(handoffs, 0);
    expect(pendingSaves, 0);
    expect(notifier.setupCalls, 0);
  });

  testWidgets('the create-password modal enrolls the checked pair', (
    tester,
  ) async {
    ServerDraft? enrolledDraft;
    Map<String, dynamic>? enrolledResult;
    String? enrolledPassphrase;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        enrolledDraft = draft;
        enrolledResult = result;
        enrolledPassphrase = passphrase;
        return const EnrollmentResult(enrolled: true);
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
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

    expect(enrolledDraft, isNotNull);
    expect(enrolledDraft!.host, '203.0.113.10');
    expect(enrolledDraft!.sshUser, 'ubuntu');
    expect(enrolledDraft!.sshPassword, 'secret');
    expect(enrolledResult, isNotNull);
    expect(enrolledPassphrase, 'topsecret');
    // The modal dismisses on success; the enrollment host drives the
    // wizard onward from there.
    expect(find.text('Create password and finish setup'), findsNothing);
  });

  testWidgets('the create-password modal reveals the passphrase on demand', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(checkResult: _successfulCheckResult());
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async =>
          const EnrollmentResult(enrolled: true),
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    final passphraseField = find.byKey(const Key('database-passphrase-field'));
    EditableText editable() => tester.widget<EditableText>(
      find.descendant(of: passphraseField, matching: find.byType(EditableText)),
    );
    expect(editable().obscureText, isTrue);
    await tester.tap(find.byKey(const Key('database-passphrase-visibility')));
    await tester.pump();
    expect(editable().obscureText, isFalse);
  });

  testWidgets('the create-password modal submits from the keyboard', (
    tester,
  ) async {
    var handoffs = 0;
    final notifier = _FakeServerNotifier(checkResult: _successfulCheckResult());
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        handoffs += 1;
        return const EnrollmentResult(enrolled: true);
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    EditableText editableFor(Key key) => tester.widget<EditableText>(
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText)),
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

    expect(handoffs, 1);
    expect(find.text('Create password and finish setup'), findsNothing);
  });

  testWidgets('the create-password modal rejects an empty passphrase', (
    tester,
  ) async {
    var handoffs = 0;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        handoffs += 1;
        return const EnrollmentResult(enrolled: true);
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a passphrase to continue.'), findsOneWidget);
    expect(handoffs, 0);
    expect(find.text('Create password and finish setup'), findsOneWidget);
  });

  testWidgets('the create-password modal rejects a mismatch', (tester) async {
    var handoffs = 0;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        handoffs += 1;
        return const EnrollmentResult(enrolled: true);
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.enterText(
      find.byKey(const Key('database-confirm-passphrase-field')),
      'different',
    );
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Passphrases do not match.'), findsOneWidget);
    expect(handoffs, 0);
    expect(find.text('Create password and finish setup'), findsOneWidget);
  });

  testWidgets('cancelling the create-password modal enrolls nothing', (
    tester,
  ) async {
    var handoffs = 0;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        handoffs += 1;
        return const EnrollmentResult(enrolled: true);
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('database-passphrase-field')),
      'topsecret',
    );
    await tester.tap(find.byKey(const Key('enrollment-cancel-button')));
    await tester.pumpAndSettle();

    expect(handoffs, 0);
    expect(find.text('Create password and finish setup'), findsNothing);
    expect(find.byKey(const Key('server-save-button')), findsOneWidget);
  });

  testWidgets('a refused enrollment keeps the modal open with the failure', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async =>
          const EnrollmentResult(
            enrolled: false,
            failureDetails: 'Bad state: encrypted database setup failed',
          ),
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
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
        'Couldn’t create the local encrypted database. Your password was '
        'not saved. Review the technical details and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Create password and finish setup'), findsOneWidget);
    expect(find.byKey(const Key('database-passphrase-field')), findsOneWidget);
    await tester.ensureVisible(find.text('Technical details'));
    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    expect(
      find.text('Bad state: encrypted database setup failed'),
      findsOneWidget,
    );
  });

  testWidgets('a throwing enrollment keeps the modal usable with the failure', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    var attempts = 0;
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onEnrollmentRequired: (draft, result, passphrase) async {
        attempts++;
        throw StateError('disk full');
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();
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
        'Couldn’t create the local encrypted database. Your password was '
        'not saved. Review the technical details and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Create password and finish setup'), findsOneWidget);
    // The modal is not stuck submitting: a second tap submits again.
    await tester.tap(find.byKey(const Key('enrollment-submit-button')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets('an enrolled-server finish never opens the password modal', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    // A database already exists, so Finish saves and provisions directly.
    expect(find.text('Create password and finish setup'), findsNothing);
    expect(notifier.setupCalls, 1);
  });

  testWidgets('an enrolled-server review shows no passphrase fields', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    expect(find.text('Protect this app'), findsNothing);
    expect(find.byKey(const Key('database-passphrase-field')), findsNothing);
  });

  testWidgets('a pending enrollment saves and provisions the seeded pair', (
    tester,
  ) async {
    ServerDraft? savedDraft;
    var handoffs = 0;
    final pending = PendingEnrollment(
      draft: const ServerDraft(
        name: 'Production web server',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'secret',
      ),
      checkResult: _successfulCheckResult(),
    );
    final notifier = _FakeServerNotifier(
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      pendingEnrollment: pending,
      onSavePendingServer: (draft, result) async {
        savedDraft = draft;
        return _pendingServer();
      },
      onAdoptManagedIdentity:
          ({
            required serverId,
            required sshUser,
            required authMethod,
            privateKey,
            publicKey,
            managedUserPassword,
          }) async {
            handoffs += 1;
          },
    );

    expect(savedDraft, isNotNull);
    expect(savedDraft!.host, '203.0.113.10');
    expect(savedDraft!.sshPassword, 'secret');
    expect(notifier.setupCalls, 1);
    expect(handoffs, 1);
    expect(find.text('Choose services'), findsOneWidget);
    // The save cleared the provider copy: a remount opens a blank wizard
    // instead of saving a second record.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ServerOnboardingView)),
    );
    expect(container.read(pendingEnrollmentProvider), isNull);
  });

  testWidgets('unmounting mid-save never faults on providers after dispose', (
    tester,
  ) async {
    final saveCompleter = Completer<Server>();
    var saveStarted = false;
    final notifier = _FakeServerNotifier(
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      pendingEnrollment: PendingEnrollment(
        draft: const ServerDraft(
          name: 'Production web server',
          host: '203.0.113.10',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        checkResult: _successfulCheckResult(),
      ),
      onSavePendingServer: (draft, result) {
        saveStarted = true;
        return saveCompleter.future;
      },
      settle: false,
    );
    await tester.pump();
    expect(saveStarted, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    saveCompleter.complete(_pendingServer());
    await tester.pump();
    await tester.pump();
  });

  testWidgets('a pending enrollment hides the review escape hatch', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      pendingEnrollment: PendingEnrollment(
        draft: const ServerDraft(
          name: 'Production web server',
          host: '203.0.113.10',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        checkResult: _successfulCheckResult(),
      ),
    );

    expect(find.text('Setup needs attention'), findsOneWidget);
    expect(find.byKey(const Key('server-setup-retry-button')), findsOneWidget);
    expect(
      find.byKey(const Key('server-setup-back-to-review-button')),
      findsNothing,
    );
  });

  testWidgets('pending save failure returns to confirmation with useful copy', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onSavePendingServer: (draft, result) async =>
          throw StateError('disk full'),
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(notifier.setupCalls, 0);
    expect(find.text('Review server details'), findsOneWidget);
    expect(find.textContaining('Couldn’t save this server'), findsOneWidget);
    expect(find.text('Setting up server'), findsNothing);
  });

  testWidgets('finish setup switches to current progress while setup runs', (
    tester,
  ) async {
    final setupCompleter = Completer<void>();
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupCompleter: setupCompleter,
      setupResult: const <String, dynamic>{'status': 'success'},
      setupEvents: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'setup_part_started',
          'message': 'Installing Docker infrastructure.',
        },
      ],
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pump();

    expect(find.text('Setting up server'), findsOneWidget);
    expect(find.byKey(const Key('server-setup-progress')), findsOneWidget);
    expect(find.text('Installing Docker infrastructure.'), findsOneWidget);
    expect(find.text('Review server details'), findsNothing);

    setupCompleter.complete();
    await tester.pumpAndSettle();

    expect(find.text('Choose services'), findsOneWidget);
  });

  testWidgets('setup progress shows the live telemetry notice switch', (
    tester,
  ) async {
    final setupCompleter = Completer<void>();
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupCompleter: setupCompleter,
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    final telemetry = _RecordingTelemetrySettingsNotifier();
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      telemetrySettingsFactory: () => telemetry,
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pump();

    expect(
      find.byKey(const Key('server-setup-telemetry-switch')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('server-setup-telemetry-switch')),
          )
          .value,
      isTrue,
    );
    expect(find.text('Help improve Deploy Dash'), findsOneWidget);

    await tester.tap(find.byKey(const Key('server-setup-telemetry-switch')));
    await tester.pump();

    expect(telemetry.setEnabledCalls, 1);
    expect(telemetry.lastEnabled, isFalse);

    setupCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('running progress separates the telemetry card from the steps', (
    tester,
  ) async {
    final setupCompleter = Completer<void>();
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupCompleter: setupCompleter,
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pump();

    expect(
      find.byKey(const Key('server-setup-telemetry-switch')),
      findsOneWidget,
    );
    final block = tester
        .widgetList<Column>(
          find.ancestor(
            of: find.byKey(const Key('server-setup-telemetry-switch')),
            matching: find.byType(Column),
          ),
        )
        .firstWhere(
          (column) => column.children.any(
            (child) =>
                child is Text && child.data == 'Current setup is running.',
          ),
        );
    final cardIndex = block.children.indexWhere(
      (child) => child.runtimeType.toString() == '_TelemetryNoticeCard',
    );
    expect(cardIndex, isNot(-1));
    expect(
      block.children[cardIndex + 1],
      isA<SizedBox>().having((gap) => gap.height, 'height', 12),
    );

    setupCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('connect shows local validation error when password missing', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await tester.enterText(
      find.byKey(const Key('server-name-field')),
      'Production web server',
    );
    await tester.enterText(
      find.byKey(const Key('server-host-field')),
      '203.0.113.10',
    );
    final connectButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-check-button')),
    );
    connectButton.onPressed?.call();
    await tester.pumpAndSettle();

    expect(find.text('Password is required'), findsOneWidget);
    expect(notifier.checkCalls, 0);
  });

  testWidgets('connect stays disabled from processing through navigation', (
    tester,
  ) async {
    final planGate = Completer<void>();
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      planGate: planGate,
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pump();

    // The check finished but the setup plan is still loading: the wizard
    // has not navigated yet, and the button must stay in processing mode
    // instead of flickering back to clickable.
    expect(find.byKey(const Key('server-save-button')), findsNothing);
    final checkButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-check-button')),
    );
    expect(checkButton.onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('server-check-button')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    planGate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-save-button')), findsOneWidget);
  });

  testWidgets('a failed connection check re-enables connect for retry', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(checkError: 'Connection refused');
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('server-save-button')), findsNothing);
    final checkButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-check-button')),
    );
    expect(checkButton.onPressed, isNotNull);
  });

  testWidgets('going back from review leaves connect usable', (tester) async {
    final notifier = _FakeServerNotifier(checkResult: _successfulCheckResult());
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-confirmation-back-button')));
    await tester.pumpAndSettle();

    final checkButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-check-button')),
    );
    expect(checkButton.onPressed, isNotNull);
  });

  testWidgets('save failure switches to progress view with useful copy', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(),
      setupResult: const <String, dynamic>{'status': 'error'},
      setupErrorPayload: const <String, dynamic>{
        'msg':
            'apt update failed: Temporary failure resolving archive.ubuntu.com',
      },
      setupError:
          'apt update failed: Temporary failure resolving archive.ubuntu.com',
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('server-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Setup needs attention'), findsOneWidget);
    expect(find.byKey(const Key('server-setup-progress-card')), findsOneWidget);
    expect(
      find.text(
        'The server could not reach a required package or download source. Check DNS, outbound HTTPS, proxy, or firewall rules, then retry setup.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('server-setup-retry-button')), findsOneWidget);
  });

  testWidgets('compatibility failures disable add server action', (
    tester,
  ) async {
    var saved = false;
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(
        compatibility: _failingCompatibility(),
      ),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(
      tester,
      serverNotifier: notifier,
      onSavePendingServer: (draft, result) async {
        saved = true;
        return _pendingServer();
      },
    );

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-save-button')),
    );
    expect(saveButton.onPressed, isNull);
    expect(
      find.byKey(const Key('server-save-blocked-compatibility')),
      findsOneWidget,
    );
    expect(
      find.text('Docker appears to already be installed.'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('server-save-button')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(notifier.setupCalls, 0);
    expect(saved, isFalse);
  });

  testWidgets('package reachability failures block setup before running it', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: _successfulCheckResult(
        compatibility: _failingReachabilityCompatibility(),
      ),
      setupResult: const <String, dynamic>{'status': 'success'},
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key(
          'server-compatibility-check-docker_package_repository_reachable',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('server-compatibility-checks-expansion')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Setup would fail while installing Docker because the Docker package repository was not reachable.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'server-compatibility-check-docker_package_repository_reachable-actual',
        ),
      ),
      findsNothing,
    );
    await tester.ensureVisible(
      find.byKey(const Key('server-compatibility-checks-expansion')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('server-compatibility-checks-expansion')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key(
          'server-compatibility-check-docker_package_repository_reachable',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Technical details: URLError: <urlopen error [Errno 101] Network is unreachable>',
      ),
      findsOneWidget,
    );
    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-save-button')),
    );
    expect(saveButton.onPressed, isNull);
    expect(notifier.setupCalls, 0);
  });

  testWidgets(
    'review shows existing admin keys as informational access state',
    (tester) async {
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(tester, serverNotifier: notifier);

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('server-compatibility-checks-expansion')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('server-compatibility-checks-expansion')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('server-compatibility-check-existing_admin_keys')),
        findsOneWidget,
      );
      expect(find.text('Deploy Dash adds 1 SSH key'), findsOneWidget);
      expect(
        find.text('ubuntu already has 2 SSH keys — they stay untouched.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('missing compatibility payload blocks add server action', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkResult: const <String, dynamic>{
        'status': 'success',
        'os': 'Ubuntu 24.04',
        'cpu': 'x86_64',
        'memory_mb': 8192,
        'disk_gb': 120,
      },
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-save-button')),
    );
    expect(saveButton.onPressed, isNull);
    expect(
      find.byKey(const Key('server-compatibility-summary')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Deploy Dash could not review this server yet. Check the connection and try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('host key mismatch opens confirmation modal and retries check', (
    tester,
  ) async {
    final notifier = _FakeServerNotifier(
      checkError: 'SSH host key mismatch detected.',
      refreshHostKeyResult: true,
    );
    await _pumpOnboarding(tester, serverNotifier: notifier);

    await _fillCredentialForm(tester);
    await tester.tap(find.byKey(const Key('server-check-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('server-accept-host-key-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('server-accept-host-key-button')));
    await tester.pumpAndSettle();
    expect(find.text('Confirm this server change'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue'), findsOneWidget);
    expect(find.bySemanticsLabel('Cancel'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Continue'))
          .flagsCollection
          .isButton,
      isTrue,
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(notifier.refreshHostKeyCalls, 1);
    expect(notifier.checkCalls, 2);
  });

  testWidgets('Services selection passes chosen Postgres version', (
    tester,
  ) async {
    bool? databasesEnabled;
    bool? enableEmail;
    bool? domainsEnabled;
    String? selectedPostgresVersion;
    List<String>? selectedExtensions;

    await _pumpOnboarding(
      tester,
      serverNotifier: _FakeServerNotifier(),
      initialStep: 'services_selection',
      onCompleteServiceSelection:
          ({
            required bool enableEmailAccounts,
            required bool enableDomains,
            required bool enableDatabases,
            required String postgresVersion,
            required List<String> postgresExtensions,
          }) async {
            enableEmail = enableEmailAccounts;
            domainsEnabled = enableDomains;
            databasesEnabled = enableDatabases;
            selectedPostgresVersion = postgresVersion;
            selectedExtensions = postgresExtensions;
          },
    );

    await tester.tap(find.byKey(const Key('service-toggle-databases')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('service-postgres-version-dropdown')),
      findsOneWidget,
    );
    expect(find.text('Postgres 17'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('service-postgres-version-dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Postgres 18').last);
    await tester.pumpAndSettle();

    expect(find.text('pg_search'), findsNothing);

    await tester.ensureVisible(
      find.byKey(const Key('service-postgres-advanced-options')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('service-postgres-advanced-options')),
    );
    await tester.pumpAndSettle();

    expect(find.text('pg_search'), findsOneWidget);

    final vectorExtension = find.byKey(
      const Key('service-postgres-extension-vector'),
    );
    await tester.ensureVisible(vectorExtension);
    await tester.pumpAndSettle();
    await tester.tap(vectorExtension);
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('services-selection-continue-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('services-selection-continue-button')),
    );
    await tester.pumpAndSettle();

    expect(databasesEnabled, isTrue);
    expect(enableEmail, isFalse);
    expect(domainsEnabled, isFalse);
    expect(selectedPostgresVersion, '18');
    expect(selectedExtensions, contains('vector'));
  });

  testWidgets('Services selection keeps email and domains toggles disabled', (
    tester,
  ) async {
    await _pumpOnboarding(
      tester,
      serverNotifier: _FakeServerNotifier(),
      initialStep: 'services_selection',
    );

    final emailToggle = tester.widget<AppToggleField>(
      find.byKey(const Key('service-toggle-email')),
    );
    final domainsToggle = tester.widget<AppToggleField>(
      find.byKey(const Key('service-toggle-domains')),
    );

    expect(emailToggle.onChanged, isNull);
    expect(domainsToggle.onChanged, isNull);
    expect(find.text('Coming soon'), findsNWidgets(2));
  });

  group('onboarding step funnel', () {
    testWidgets('successful setup reports the checkpoint sequence in order', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      var saved = false;
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        analyticsService: analytics,
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              saved = true;
            },
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();

      expect(saved, isTrue);
      expect(
        analytics.onboardingSteps,
        _successfulOnboardingSequence(attempt: 1),
      );
    });

    testWidgets('setup retry carries the next attempt number', (tester) async {
      final analytics = FakeAnalyticsService();
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
        setupResult: const <String, dynamic>{'status': 'error'},
        setupError: 'managed login could not be verified after sshd restart',
        setupErrorPayload: const <String, dynamic>{
          'code': 'ENGINE_SSH_HARDENING_ROLLBACK_FAILED',
          'msg': 'managed login could not be verified after sshd restart',
        },
      );
      var saved = false;
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        analyticsService: analytics,
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              saved = true;
            },
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Setup needs attention'), findsOneWidget);
      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.sshHardened, succeeded: false, attempt: 1),
      ]);

      notifier.setupResult = const <String, dynamic>{'status': 'success'};
      notifier.setupError = null;
      notifier.setupErrorPayload = null;
      await tester.tap(find.byKey(const Key('server-setup-retry-button')));
      await tester.pumpAndSettle();

      expect(saved, isTrue);
      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.sshHardened, succeeded: false, attempt: 1),
        ..._successfulOnboardingSequence(attempt: 2),
      ]);
    });

    testWidgets('closing the wizard before setup reports abandon', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(),
        analyticsService: analytics,
      );

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.abandoned, succeeded: false, attempt: 0),
      ]);
    });

    testWidgets('closing after a failed setup still reports abandon', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(
          checkResult: _successfulCheckResult(),
          setupResult: const <String, dynamic>{'status': 'error'},
          setupError: 'managed login could not be verified',
          setupErrorPayload: const <String, dynamic>{
            'code': 'ENGINE_SSH_HARDENING_ROLLBACK_FAILED',
            'msg': 'managed login could not be verified',
          },
        ),
        analyticsService: analytics,
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();
      expect(find.text('Setup needs attention'), findsOneWidget);

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.sshHardened, succeeded: false, attempt: 1),
        (step: OnboardingStep.abandoned, succeeded: false, attempt: 0),
      ]);
    });

    testWidgets('confirming the host-key change reports a kept step', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final notifier = _FakeServerNotifier(
        checkError: 'SSH host key mismatch detected.',
        refreshHostKeyResult: true,
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        analyticsService: analytics,
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-accept-host-key-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(notifier.refreshHostKeyCalls, 1);
      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.hostkeyMismatch, succeeded: true, attempt: 0),
      ]);
    });

    testWidgets('dismissing the host-key change reports a dropped step', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final notifier = _FakeServerNotifier(
        checkError: 'SSH host key mismatch detected.',
        refreshHostKeyResult: true,
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        analyticsService: analytics,
      );

      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-accept-host-key-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('server-host-key-change-cancel-button')),
      );
      await tester.pumpAndSettle();

      expect(notifier.refreshHostKeyCalls, 0);
      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.hostkeyMismatch, succeeded: false, attempt: 0),
      ]);
    });
  });

  group('setup retry for early-saved servers', () {
    ServerCatalogState pendingCatalog() {
      final server = _pendingServer();
      return ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: [server],
        selectedServerId: server.id,
        onboardingStep: 'setup_in_progress',
        pendingSetupServerIds: {server.id},
      );
    }

    const bootstrapPayload = <String, dynamic>{
      'host': '203.0.113.10',
      'port': 22,
      'username': 'root',
      'password': 'bootstrap-secret',
    };

    testWidgets('retry provisions from stored credentials and hands off', (
      tester,
    ) async {
      var handoffServerId = 'unset';
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        retryServerId: 'server-pending-1',
        catalogState: pendingCatalog(),
        resolvePayload: (server) async => bootstrapPayload,
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              handoffServerId = serverId;
            },
      );
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 1);
      expect(notifier.lastSetupPassword, 'bootstrap-secret');
      expect(handoffServerId, 'server-pending-1');
      expect(find.text('Choose services'), findsOneWidget);
    });

    testWidgets('retry reports a server that is no longer saved', (
      tester,
    ) async {
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        retryServerId: 'server-pending-1',
        catalogState: const ServerCatalogState(isLoading: false),
        resolvePayload: (server) async => bootstrapPayload,
      );
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 0);
      expect(find.textContaining('no longer saved'), findsOneWidget);
    });

    testWidgets('retry refuses a server that already finished setup', (
      tester,
    ) async {
      final server = _pendingServer();
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        retryServerId: server.id,
        catalogState: ServerCatalogState(
          isLoading: false,
          onboardingComplete: true,
          servers: [server],
          selectedServerId: server.id,
          onboardingStep: 'connected',
          pendingSetupServerIds: const {},
        ),
        resolvePayload: (server) async => bootstrapPayload,
      );
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 0);
      expect(find.textContaining('already finished setup'), findsOneWidget);
    });

    testWidgets('retry reports unresolvable credentials', (tester) async {
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        retryServerId: 'server-pending-1',
        catalogState: pendingCatalog(),
        resolvePayload: (server) async => null,
      );
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 0);
      expect(find.textContaining('credentials are incomplete'), findsOneWidget);
    });

    testWidgets('retry mode hides back to review', (tester) async {
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        retryServerId: 'server-pending-1',
        catalogState: pendingCatalog(),
        resolvePayload: (server) async => null,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('server-setup-retry-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('server-setup-back-to-review-button')),
        findsNothing,
      );
    });

    testWidgets('retry button re-runs a failed retry', (tester) async {
      var handoffs = 0;
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'error'},
        setupError: 'apt update failed',
      );
      await _pumpOnboarding(
        tester,
        serverNotifier: notifier,
        retryServerId: 'server-pending-1',
        catalogState: pendingCatalog(),
        resolvePayload: (server) async => bootstrapPayload,
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              handoffs += 1;
            },
      );
      await tester.pumpAndSettle();
      expect(notifier.setupCalls, 1);
      expect(handoffs, 0);

      notifier.setupResult = const <String, dynamic>{'status': 'success'};
      notifier.setupError = null;
      await tester.tap(find.byKey(const Key('server-setup-retry-button')));
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 2);
      expect(handoffs, 1);
      expect(find.text('Choose services'), findsOneWidget);
    });

    testWidgets('unmount during credential resolve drops the retry silently', (
      tester,
    ) async {
      final resolveGate = Completer<Map<String, dynamic>?>();
      final notifier = _FakeServerNotifier(
        setupResult: const <String, dynamic>{'status': 'success'},
      );
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: notifier,
        analyticsService: FakeAnalyticsService(),
        retryServerId: 'server-pending-1',
        catalogState: pendingCatalog(),
        resolvePayload: (server) => resolveGate.future,
      );

      shell.hide();
      // Apply the unmount before completing: the resolve continuation must
      // observe !mounted, and a bare complete would win the microtask race
      // against the pending hide frame.
      await tester.pump();
      resolveGate.complete(bootstrapPayload);
      await tester.pumpAndSettle();

      expect(notifier.setupCalls, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('onboarding completion event', () {
    Future<void> reachServicesStep(WidgetTester tester) async {
      await _fillCredentialForm(tester);
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('server-save-button')));
      await tester.pumpAndSettle();
      expect(find.text('Choose services'), findsOneWidget);
    }

    testWidgets('closing after services completion reports success', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      var servicesCompleted = false;
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(
          checkResult: _successfulCheckResult(),
          setupResult: const <String, dynamic>{'status': 'success'},
        ),
        analyticsService: analytics,
        onCompleteServiceSelection:
            ({
              required bool enableEmailAccounts,
              required bool enableDomains,
              required bool enableDatabases,
              required String postgresVersion,
              required List<String> postgresExtensions,
            }) async {
              servicesCompleted = true;
            },
      );

      await reachServicesStep(tester);
      final continueButton = find.byKey(
        const Key('services-selection-continue-button'),
      );
      await tester.ensureVisible(continueButton);
      await tester.pumpAndSettle();
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      expect(servicesCompleted, isTrue);

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingEvents, [
        (
          outcome: DataOperationOutcome.success,
          provider: OnboardingAuthProvider.password,
          stage: OnboardingStage.services,
        ),
      ]);
      expect(analytics.userAttributes, [
        (attribute: AppUserAttribute.hasCompletedOnboarding, value: 'true'),
      ]);
    });

    testWidgets('closing before services completion reports failure', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(
          checkResult: _successfulCheckResult(),
          setupResult: const <String, dynamic>{'status': 'success'},
        ),
        analyticsService: analytics,
      );

      await reachServicesStep(tester);

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingEvents, [
        (
          outcome: DataOperationOutcome.failure,
          provider: OnboardingAuthProvider.password,
          stage: OnboardingStage.services,
        ),
      ]);
      expect(analytics.userAttributes, isEmpty);
    });

    testWidgets('closing on the credentials step reports its stage', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(),
        analyticsService: analytics,
      );

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingEvents, [
        (
          outcome: DataOperationOutcome.failure,
          provider: OnboardingAuthProvider.password,
          stage: OnboardingStage.credentials,
        ),
      ]);
    });

    testWidgets('closing on the intro step reports its stage', (tester) async {
      final analytics = FakeAnalyticsService();
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(),
        analyticsService: analytics,
        firstRun: true,
      );

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingEvents, [
        (
          outcome: DataOperationOutcome.failure,
          provider: OnboardingAuthProvider.password,
          stage: OnboardingStage.intro,
        ),
      ]);
    });

    testWidgets('ssh-key onboarding reports the key provider', (tester) async {
      final analytics = FakeAnalyticsService();
      final shell = await _pumpWizardShell(
        tester,
        serverNotifier: _FakeServerNotifier(),
        analyticsService: analytics,
      );

      await tester.ensureVisible(find.text('SSH key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH key'));
      await tester.pumpAndSettle();

      shell.hide();
      await tester.pumpAndSettle();

      expect(analytics.onboardingEvents, [
        (
          outcome: DataOperationOutcome.failure,
          provider: OnboardingAuthProvider.sshKey,
          stage: OnboardingStage.credentials,
        ),
      ]);
    });

    testWidgets('key import keeps the soft-null empty path + sibling pub', (
      tester,
    ) async {
      // D-69p1 characterization: an empty private file nulls (no import
      // error) while the sibling .pub is still picked up. Sync I/O: async
      // dart:io never completes under testWidgets without a pump.
      final tempDirectory = Directory.systemTemp.createTempSync(
        'deploydash-key-import-',
      );
      addTearDown(() {
        if (tempDirectory.existsSync()) {
          tempDirectory.deleteSync(recursive: true);
        }
      });
      final privateFile = File('${tempDirectory.path}/id_ed25519');
      privateFile.writeAsStringSync('   \n');
      File('${privateFile.path}.pub').writeAsStringSync('ssh-ed25519 AAA\n');

      final originalSelector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _FakeKeyFileSelector(privateFile.path);
      addTearDown(() => FileSelectorPlatform.instance = originalSelector);

      await _pumpOnboarding(tester, serverNotifier: _FakeServerNotifier());
      await tester.ensureVisible(find.text('SSH key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH key'));
      await tester.pumpAndSettle();
      // The form scrolls under the pinned footer: bring the import
      // button into view before tapping it.
      await tester.ensureVisible(
        find.byKey(const Key('server-key-picker-button')),
      );
      await tester.pumpAndSettle();
      // The import handler awaits real file reads, which never complete in
      // the fake zone: tap inside runAsync so its futures are real.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('server-key-picker-button')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Failed to import SSH private key'),
        findsNothing,
      );
      expect(
        tester
            .widget<AppTextFormField>(
              find.byKey(const Key('server-key-path-field')),
            )
            .controller
            ?.text,
        'id_ed25519',
      );
    });

    testWidgets('key import stores the private key byte-identical', (
      tester,
    ) async {
      // D-69p1 characterization: the saved draft carries the private key
      // byte-identical (untrimmed) and the sibling pub trimmed. Sync I/O:
      // async dart:io never completes under testWidgets without a pump.
      final tempDirectory = Directory.systemTemp.createTempSync(
        'deploydash-key-import-',
      );
      addTearDown(() {
        if (tempDirectory.existsSync()) {
          tempDirectory.deleteSync(recursive: true);
        }
      });
      final privateFile = File('${tempDirectory.path}/id_ed25519');
      privateFile.writeAsStringSync('PRIVATE KEY\n');
      File('${privateFile.path}.pub').writeAsStringSync('ssh-ed25519 AAA\n');

      final originalSelector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _FakeKeyFileSelector(privateFile.path);
      addTearDown(() => FileSelectorPlatform.instance = originalSelector);

      // The check call carries the imported private key verbatim; the save
      // flow swaps in a managed keypair, so the check capture is the
      // untrimmed pin. (The imported PUBLIC key is widget-unobservable —
      // neither check nor save forwards it — so its trim behavior rests on
      // the reader's pinned sibling block, which the routed handler mirrors
      // verbatim.)
      final notifier = _FakeServerNotifier(
        checkResult: _successfulCheckResult(),
      );
      await _pumpOnboarding(tester, serverNotifier: notifier);

      await tester.ensureVisible(find.text('SSH key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH key'));
      await tester.pumpAndSettle();
      // The form scrolls under the pinned footer: bring the import
      // button into view before tapping it.
      await tester.ensureVisible(
        find.byKey(const Key('server-key-picker-button')),
      );
      await tester.pumpAndSettle();
      // The import handler awaits real file reads, which never complete in
      // the fake zone: tap inside runAsync so its futures are real.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('server-key-picker-button')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Failed to import SSH private key'),
        findsNothing,
      );
      expect(
        tester
            .widget<AppTextFormField>(
              find.byKey(const Key('server-key-path-field')),
            )
            .controller
            ?.text,
        'id_ed25519',
      );

      await tester.enterText(
        find.byKey(const Key('server-name-field')),
        'Production web server',
      );
      await tester.enterText(
        find.byKey(const Key('server-host-field')),
        '203.0.113.10',
      );
      await tester.tap(find.byKey(const Key('server-check-button')));
      await tester.pumpAndSettle();

      expect(notifier.lastCheckPrivateKey, 'PRIVATE KEY\n');
    });
  });
}

class _FakeKeyFileSelector extends FileSelectorPlatform {
  _FakeKeyFileSelector(this.openFilePath);

  final String openFilePath;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? confirmButtonText,
    String? initialDirectory,
    bool lockParentWindow = false,
  }) async {
    return XFile(openFilePath);
  }
}

/// The exact rows one successful setup run reports: every baseline
/// checkpoint in fixed order, then the completion marker.
List<({OnboardingStep step, bool succeeded, int attempt})>
_successfulOnboardingSequence({required int attempt}) {
  return <({OnboardingStep step, bool succeeded, int attempt})>[
    (step: OnboardingStep.bootstrap, succeeded: true, attempt: attempt),
    (
      step: OnboardingStep.ubuntuLoginVerified,
      succeeded: true,
      attempt: attempt,
    ),
    (step: OnboardingStep.sshHardened, succeeded: true, attempt: attempt),
    (step: OnboardingStep.firewallBaselined, succeeded: true, attempt: attempt),
    (step: OnboardingStep.fail2ban, succeeded: true, attempt: attempt),
    (step: OnboardingStep.autoUpdates, succeeded: true, attempt: attempt),
    (step: OnboardingStep.dockerPinned, succeeded: true, attempt: attempt),
    (step: OnboardingStep.railpackPinned, succeeded: true, attempt: attempt),
    (step: OnboardingStep.ownershipHandoff, succeeded: true, attempt: attempt),
    (step: OnboardingStep.completed, succeeded: true, attempt: attempt),
  ];
}
