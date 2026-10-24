part of '../e2e_checklist_test.dart';

Future<void> _runHostKeyRecoveryScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  binding.shouldPropagateDevicePointerEvents = false;
  final suffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E host key recovery $suffix';
  final projectSlug = _e2eProjectSlug(projectName);
  await _createProject(tester, name: projectName, runtime: 'PHP');
  // The Laravel fixture needs APP_KEY for the strict public health check that
  // follows repository identity acceptance. Configure it through the same
  // visible environment editor used by deployment E2E paths.
  await _exerciseEnvironmentEditor(tester);
  await _ensureGitHubRepositorySelected(tester, binding);
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  await _exerciseDeploymentPreflight(tester);

  await _startRepositoryDeploy(tester);
  await _waitFor(
    tester,
    find.byKey(const Key('repository-host-key-dialog')),
    description: 'first repository host-key confirmation',
    timeout: const Duration(minutes: 2),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(TextButton, 'Cancel').last,
    description: 'cancel repository host trust',
  );
  await _waitForAbsent(
    tester,
    find.byKey(const Key('repository-host-key-dialog')),
    description: 'cancelled repository host trust',
  );
  _pass(
    'GitHub And Repository Flow::GitHub SSH trust cancel path',
    'Cancelled first-time repository trust and confirmed Deploy Dash did not continue the deployment.',
  );

  await _startRepositoryDeploy(tester);
  await _waitFor(
    tester,
    find.byKey(const Key('repository-host-key-dialog')),
    description: 'repository host-key confirmation retry',
    timeout: const Duration(minutes: 2),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Trust and retry').last,
    description: 'trust repository host key',
  );
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'deployed app after repository trust',
    timeout: const Duration(minutes: 12),
  );
  _pass(
    'GitHub And Repository Flow::Inline deploy-key GitHub SSH trust prompt',
    'Explicitly trusted the scanned repository identity and completed the strict retry.',
  );

  await _runRequiredVmScript(
    r'''set -eu
KNOWN="/opt/deploydash/stack/apps/.deploydash/repository-known-hosts/${PROJECT_SLUG}/known_hosts"
mkdir -p "$(dirname "${KNOWN}")"
set -- $(cat /etc/ssh/ssh_host_ed25519_key.pub)
printf 'github.com %s %s\n' "$1" "$2" > "${KNOWN}"
chmod 600 "${KNOWN}"
''',
    description: 'changed repository host-key fixture',
    environment: <String, String>{'PROJECT_SLUG': projectSlug},
    sudo: true,
  );
  await _startRepositoryDeploy(tester);
  await _waitFor(
    tester,
    find.byKey(const Key('repository-host-key-dialog')),
    description: 'changed repository host-key confirmation',
    timeout: const Duration(minutes: 2),
  );
  expect(find.textContaining('Previous fingerprint:'), findsOneWidget);
  await _tapFinder(
    tester,
    find.widgetWithText(TextButton, 'Cancel').last,
    description: 'cancel changed repository identity',
  );
  await _startRepositoryDeploy(tester);
  await _waitFor(
    tester,
    find.byKey(const Key('repository-host-key-dialog')),
    description: 'changed repository host-key retry',
    timeout: const Duration(minutes: 2),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Trust and retry').last,
    description: 'replace changed repository host key',
  );
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'redeployed app after changed repository identity',
    timeout: const Duration(minutes: 12),
  );
  _pass(
    'GitHub And Repository Flow::GitHub SSH changed-host-key path',
    'Cancelled, reviewed, and then explicitly replaced a changed repository host identity.',
  );

  await _runRequiredVmScript(
    r'''set -eu
rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
rm -f /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub
rm -f /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -A
printf 'ubuntu:%s\n' "${VM_PASSWORD}" | chpasswd
for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -f "${file}" ] || continue
  sed -i -E 's/^[#[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication yes/' "${file}"
done
cat >/etc/ssh/sshd_config.d/00-deploydash-e2e-password.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
sshd -t
sshd -T | grep -Fx 'passwordauthentication yes'
systemctl restart ssh
''',
    description: 'changed server host-key fixture',
    environment: <String, String>{'VM_PASSWORD': _vmPassword},
    sudo: true,
  );
  await _openHome(tester);
  await _tap(tester, const Key('home-add-server-button'));
  await _openFirstRunOnboarding(tester);
  await tester.enterText(
    find.byKey(const Key('server-name-field')),
    'E2E rotated server identity',
  );
  await tester.enterText(find.byKey(const Key('server-host-field')), _vmHost);
  await tester.enterText(find.byKey(const Key('server-user-field')), _vmUser);
  await tester.enterText(
    find.byKey(const Key('server-password-field')),
    _vmPassword,
  );
  await _tap(tester, const Key('server-check-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-accept-host-key-button')),
    description: 'server host-key mismatch action',
    timeout: const Duration(minutes: 2),
  );
  await _tap(tester, const Key('server-accept-host-key-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-host-key-change-dialog')),
    description: 'server host-key mismatch dialog',
  );
  expect(find.textContaining('Saved fingerprint:'), findsOneWidget);
  expect(find.textContaining('New fingerprint:'), findsOneWidget);
  await _tap(tester, const Key('server-host-key-change-cancel-button'));
  expect(find.byKey(const Key('server-check-error-status')), findsOneWidget);
  await _tap(tester, const Key('server-accept-host-key-button'));
  await _tap(tester, const Key('server-host-key-change-confirm-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-save-button')),
    description: 'server connection after host-key replacement',
    timeout: const Duration(minutes: 4),
  );
  _pass(
    'Server Onboarding::Server host-key mismatch confirmation',
    'Cancelled and then explicitly accepted a changed server fingerprint before reconnection.',
  );
}
