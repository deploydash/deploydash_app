import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management system tab.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('System tab toggles SSH controls', (WidgetTester tester) async {
    final sshService = SystemWorkflowSshService();
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final systemTab = find.byKey(const Key('server-management-system-tab'));
    expect(sshService.systemStatusCalls, greaterThanOrEqualTo(1));
    // The apply toolbar (button plus 'Unsaved changes' label) only mounts
    // while a change is staged; asserting it is absent here is the current
    // equivalent of the persistent 'In sync' label removed on 2026-08-05
    // (a67a6b2), which no longer exists anywhere in the app.
    expect(find.byKey(const Key('system-apply-button')), findsNothing);
    expect(
      find.descendant(of: systemTab, matching: find.text('Root login')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: systemTab,
        matching: find.text('Password Authentication'),
      ),
      findsOneWidget,
    );
    final rootLoginDropdown = find.byKey(
      const Key('system-root-login-mode-dropdown'),
    );
    await tester.ensureVisible(rootLoginDropdown);
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsOneWidget);
    await tester.tap(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Key only').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('system-apply-button')), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
    final passwordAuthSwitch = find.byKey(
      const Key('system-password-auth-switch'),
    );
    await tester.ensureVisible(passwordAuthSwitch);
    await tester.pumpAndSettle();
    await tester.tap(passwordAuthSwitch);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: systemTab, matching: find.text('Key only')),
      findsOneWidget,
    );
    final systemScrollable = find
        .descendant(of: systemTab, matching: find.byType(Scrollable))
        .first;
    for (var attempt = 0; attempt < 5; attempt += 1) {
      if (find.byKey(const Key('system-swap-value')).evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(systemScrollable, const Offset(0, -600));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('system-swap-value')), findsOneWidget);
    expect(find.textContaining('GB selected'), findsOneWidget);
  });

  testWidgets('System tab prompts for and verifies a required restart', (
    WidgetTester tester,
  ) async {
    final sshService = SystemWorkflowSshService(rebootRequired: true);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Security updates need a server restart'), findsOneWidget);
    expect(find.textContaining('linux-image-6.8.0-85-generic'), findsOneWidget);
    expect(find.textContaining('libc6'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('system-enable-auto-restarts-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('system-apply-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('system-restart-server-button')));
    await tester.pumpAndSettle();

    expect(find.text('Restart server now?'), findsOneWidget);
    expect(find.textContaining('brief downtime'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restart server'));
    await tester.pumpAndSettle();

    expect(sshService.systemRestartCalls, 1);
    expect(
      find.text('Server restarted and health checks passed.'),
      findsOneWidget,
    );
    expect(find.text('Security updates need a server restart'), findsNothing);
  });

  testWidgets('System tab can update the saved server address', (
    WidgetTester tester,
  ) async {
    final sshService = SystemWorkflowSshService();
    final catalogNotifier = FakeServerCatalogNotifier(
      ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: const [serverWithCredentials],
        selectedServerId: serverWithCredentials.id,
      ),
    );

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        serverCatalogProvider.overrideWith(() => catalogNotifier),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('system-server-host-input')),
      ' ssh.deploydash.com ',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('system-save-server-host-button')));
    await tester.pumpAndSettle();

    expect(catalogNotifier.state.selectedServer?.id, serverWithCredentials.id);
    expect(catalogNotifier.state.selectedServer?.host, 'ssh.deploydash.com');
    expect(
      find.text(
        'Server address saved. Future actions will connect to '
        'ssh.deploydash.com.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('System tab validates the saved server address', (
    WidgetTester tester,
  ) async {
    final sshService = SystemWorkflowSshService();
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('system-server-host-input')),
      'not a valid host',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('system-save-server-host-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Enter a valid host, IPv4 address, or IPv6 address'),
      findsOneWidget,
    );
  });

  testWidgets('System tab applies staged settings via workflow', (
    WidgetTester tester,
  ) async {
    final sshService = SystemWorkflowSshService();
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final rootLoginDropdown = find.byKey(
      const Key('system-root-login-mode-dropdown'),
    );
    await tester.ensureVisible(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Password allowed').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('system-ssh-port-input')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('system-ssh-port-input')),
      '2022',
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('system-apply-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('system-apply-button')));
    await tester.pumpAndSettle();

    expect(find.text('Allow password login as root?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Apply'),
      ),
    );
    await tester.pumpAndSettle();

    expect(sshService.systemApplyCalls, 1);
    expect(
      sshService.lastApplySettings?['root_login_mode'],
      'password_allowed',
    );
    expect(sshService.lastApplySettings?['root_login_enabled'], true);
    expect(sshService.lastApplySettings?['ssh_port'], 2022);
    expect(
      sshService.lastApplySettings?['automatic_security_updates_enabled'],
      true,
    );
    expect(
      find.text('Server system settings applied successfully.'),
      findsOneWidget,
    );
  });

  testWidgets('System tab uses the general warning for key-only root access', (
    WidgetTester tester,
  ) async {
    final sshService = SystemWorkflowSshService();
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final rootLoginDropdown = find.byKey(
      const Key('system-root-login-mode-dropdown'),
    );
    await tester.ensureVisible(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Key only').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('system-apply-button')));
    await tester.pumpAndSettle();

    expect(find.text('Apply risky SSH changes?'), findsOneWidget);
    expect(find.textContaining('restore the exact SSH backup'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(sshService.systemApplyCalls, 0);
  });

  testWidgets('System tab risky apply proceeds after Apply confirmation', (
    WidgetTester tester,
  ) async {
    // D-70 (T-012): the risky-SSH dialog pops true on Apply, so the staged
    // apply runs exactly once with the staged settings.
    final sshService = SystemWorkflowSshService();
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final rootLoginDropdown = find.byKey(
      const Key('system-root-login-mode-dropdown'),
    );
    await tester.ensureVisible(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(rootLoginDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Key only').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('system-apply-button')));
    await tester.pumpAndSettle();

    expect(find.text('Apply risky SSH changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    expect(sshService.systemApplyCalls, 1);
    expect(sshService.lastApplySettings?['root_login_mode'], 'key_only');
  });

  testWidgets('System tab shows forced-command root access as read-only', (
    WidgetTester tester,
  ) async {
    final sshService = SystemWorkflowSshService(rootLoginMode: 'restricted');
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final restrictedMode = find.byKey(
      const Key('system-root-login-mode-readonly'),
    );
    await tester.ensureVisible(restrictedMode);
    await tester.pumpAndSettle();

    expect(restrictedMode, findsOneWidget);
    expect(find.text('Restricted (forced commands only)'), findsOneWidget);
    expect(
      find.byKey(const Key('system-root-login-mode-dropdown')),
      findsNothing,
    );
  });

  testWidgets('System tab shows imported SSH key controls for SSH key auth', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: serverWithImportedKey);
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('system-replace-ssh-key-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('system-ssh-key-summary')), findsOneWidget);
    expect(find.text('Imported key stored in Deploy Dash'), findsOneWidget);
    expect(
      find.byKey(const Key('system-replace-ssh-key-button')),
      findsOneWidget,
    );
  });

  testWidgets('System tab confirms SSH key replacement after import', (
    WidgetTester tester,
  ) async {
    final catalogNotifier = FakeServerCatalogNotifier(
      ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: const [serverWithImportedKey],
        selectedServerId: serverWithImportedKey.id,
      ),
    );

    await pumpServerManagement(
      tester,
      server: serverWithImportedKey,
      overrides: [serverCatalogProvider.overrideWith(() => catalogNotifier)],
      pickSshKeyFile: () async => XFile('/tmp/new-key'),
      importSshKeyFile: (_) async => const ImportedSshKeyFile(
        fileName: 'new-key',
        privateKey: 'NEW PRIVATE KEY',
        publicKey: 'ssh-ed25519 NEW',
      ),
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('system-replace-ssh-key-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('system-replace-ssh-key-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('SSH key updated'), findsOneWidget);
    expect(
      find.textContaining(
        'Deploy Dash imported new-key and saved it in the encrypted local database.',
      ),
      findsOneWidget,
    );
    expect(find.text('new-key'), findsOneWidget);
    expect(
      find.text('SSH key updated. Future connections will use the new key.'),
      findsOneWidget,
    );
    expect(catalogNotifier.importedPrivateKey, 'NEW PRIVATE KEY');
    expect(catalogNotifier.importedPublicKey, 'ssh-ed25519 NEW');

    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('SSH key updated'), findsNothing);
  });

  testWidgets('System tab shows an SSH key import error dialog', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(
      tester,
      server: serverWithImportedKey,
      pickSshKeyFile: () async => XFile('/tmp/bad-key'),
      importSshKeyFile: (_) => Future<ImportedSshKeyFile>.error(
        const FormatException('The selected private key file is empty.'),
      ),
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('system-replace-ssh-key-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('system-replace-ssh-key-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Couldn\'t import SSH key'), findsOneWidget);
    expect(
      find.textContaining('The selected private key file is empty.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t import SSH key'), findsNothing);
  });

  testWidgets('System tab leaves the SSH key unchanged when picker cancels', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(
      tester,
      server: serverWithImportedKey,
      pickSshKeyFile: () async => null,
      importSshKeyFile: (_) async =>
          const ImportedSshKeyFile(fileName: 'unused', privateKey: 'unused'),
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('system-replace-ssh-key-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('system-replace-ssh-key-button')));
    await tester.pumpAndSettle();

    expect(find.text('SSH key updated'), findsNothing);
    expect(find.text('Imported key stored in Deploy Dash'), findsOneWidget);
  });
}
