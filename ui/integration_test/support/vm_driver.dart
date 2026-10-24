part of '../e2e_checklist_test.dart';

bool get _useSshVmTransport => _e2eSshTransport.trim().toLowerCase() == 'ssh';

String _vmTargetLabel() {
  if (_useSshVmTransport) {
    return '${_vmUser.trim()}@${_vmHost.trim()}:$_vmPort';
  }
  return _vmName.trim();
}

/// The SSH login for harness shell commands: the verify user when one is
/// configured (it survives onboarding takeover), else the app-flow user.
String _vmSshLoginUser() {
  final verifyUser = _e2eSshVerifyUser.trim();
  return verifyUser.isNotEmpty ? verifyUser : _vmUser.trim();
}

/// Command prefix that executes its trailing arguments on the E2E target:
/// `multipass exec <vm> -- …` by default, or direct `ssh …` when
/// `DEPLOYDASH_E2E_SSH_TRANSPORT=ssh` (droplet-equivalent targets).
String? _cachedVmKeyPath;

/// Materializes the configured SSH key inside the app-data directory.
///
/// The sandboxed test host cannot open key files from shared locations
/// (even for reads), and neither can the `ssh` children it spawns, so the
/// key travels as base64 in a dart-define and is written where this process
/// demonstrably writes: the app-data directory that holds its database. The
/// copy is created once per run with owner-only permissions.
Future<String> _localVmKeyPath({required String description}) async {
  final cached = _cachedVmKeyPath;
  if (cached != null) {
    return cached;
  }
  final material = _e2eSshKeyMaterialB64.trim();
  if (material.isEmpty) {
    fail(
      '$description requires DEPLOYDASH_E2E_SSH_KEY_MATERIAL_B64 in ssh '
      'transport mode.',
    );
  }
  late final List<int> keyBytes;
  try {
    keyBytes = base64Decode(material);
  } on FormatException {
    fail('$description received undecodable SSH key material.');
  }
  final appData = await resolveAppDataDirectory();
  final localPath = '${appData.path}${Platform.pathSeparator}slim-e2e-ssh-key';
  await File(localPath).writeAsBytes(keyBytes, flush: true);
  await Process.run('chmod', <String>['600', localPath]);
  _cachedVmKeyPath = localPath;
  return localPath;
}

Future<List<String>> _vmShellPrefix({required String description}) async {
  if (_useSshVmTransport) {
    final host = _vmHost.trim();
    final keyPath = await _localVmKeyPath(description: description);
    if (host.isEmpty) {
      fail(
        '$description requires DEPLOYDASH_E2E_VM_HOST in ssh transport mode.',
      );
    }
    return <String>[
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'StrictHostKeyChecking=accept-new',
      // The sandboxed test host cannot write the user's known_hosts file, so
      // accept-new keys are acknowledged per connection and discarded. Fresh
      // trust every run is exactly what disposable QA targets want.
      '-o',
      'UserKnownHostsFile=/dev/null',
      '-o',
      'ConnectTimeout=30',
      '-i',
      keyPath,
      '-p',
      '$_vmPort',
      '${_vmSshLoginUser()}@$host',
    ];
  }
  final vmName = _vmName.trim();
  if (vmName.isEmpty) {
    fail('$description requires DEPLOYDASH_E2E_VM_NAME.');
  }
  return <String>[_multipassBin, 'exec', vmName, '--'];
}

Future<ProcessResult> _runRequiredVmScript(
  String script, {
  required String description,
  Map<String, String> environment = const <String, String>{},
  Duration timeout = const Duration(minutes: 3),
  bool sudo = false,
}) async {
  final prefix = await _vmShellPrefix(description: description);
  final target = _vmTargetLabel();
  final result = await Process.run(
    prefix.first,
    <String>[
      ...prefix.skip(1),
      if (sudo) ...<String>['sudo', '-H', '-n'],
      'env',
      for (final entry in environment.entries) '${entry.key}=${entry.value}',
      'bash',
      '-lc',
      script,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(timeout);
  if (result.exitCode != 0) {
    fail(
      '$description failed on $target.\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  final output = result.stdout.toString().trim();
  if (output.isNotEmpty) {
    stdout.writeln('DEPLOYDASH_E2E_VM_VERIFICATION[$description]');
    stdout.writeln(output);
  }
  return result;
}

Future<void> _armFirstRouteFailureInsideVm({
  required String projectSlug,
  required String domain,
}) async {
  const script = r'''
set -eu
SITE_FILE="/opt/deploydash/stack/http/caddy/conf.d/20-${PROJECT_SLUG}.caddy"
MARKER="/tmp/deploydash-e2e-caddy-fault-${PROJECT_SLUG}.marker"
LOG_FILE="/tmp/deploydash-e2e-caddy-fault-${PROJECT_SLUG}.log"
FAULT_SCRIPT="/tmp/deploydash-e2e-caddy-fault-${PROJECT_SLUG}.sh"
[ ! -e "${SITE_FILE}" ] || {
  echo "Refusing to replace an existing E2E Caddy route: ${SITE_FILE}" >&2
  exit 1
}
sudo -H -n rm -f "${MARKER}" "${LOG_FILE}" "${FAULT_SCRIPT}"
sudo -H -n tee "${FAULT_SCRIPT}" >/dev/null <<'EOF'
#!/bin/bash
set -eu
exec >"${LOG_FILE}" 2>&1
for _ in $(seq 1 1200); do
  if [ -s "${SITE_FILE}" ] && grep -Fq "reverse_proxy" "${SITE_FILE}"; then
    CODE="$(curl -ksS -o /dev/null -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/up" || true)"
    if [ "${CODE}" != "200" ]; then
      sleep 0.1
      continue
    fi
    printf "%s {\\n  respond \"forced E2E post-cutover failure\" 503\\n}\\n" "${DOMAIN}" > "${SITE_FILE}"
    touch "${MARKER}"
    docker exec deploydash_caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    docker exec deploydash_caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    exit 0
  fi
  sleep 0.1
done
echo "Timed out waiting for ${SITE_FILE}" >&2
exit 1
EOF
sudo -H -n chmod 700 "${FAULT_SCRIPT}"
sudo -H -n env \
  SITE_FILE="${SITE_FILE}" \
  MARKER="${MARKER}" \
  LOG_FILE="${LOG_FILE}" \
  DOMAIN="${DOMAIN}" \
  nohup "${FAULT_SCRIPT}" >/dev/null 2>&1 &
FAULT_PID=$!
sleep 0.1
kill -0 "${FAULT_PID}"
printf 'fault_pid=%s\n' "${FAULT_PID}"
printf 'site_file=%s\n' "${SITE_FILE}"
''';
  await _runRequiredVmScript(
    script,
    description: 'Arm first-release Caddy route fault',
    environment: <String, String>{
      'PROJECT_SLUG': projectSlug,
      'DOMAIN': domain,
    },
  );
}

Future<void> _trustCaddyInternalCaInsideVm() async {
  const script = r'''
set -eu
CA_PATH="/usr/local/share/ca-certificates/deploydash-e2e-caddy-local-root.crt"
sudo -H -n docker exec deploydash_caddy cat /data/caddy/pki/authorities/local/root.crt \
  | sudo -H -n tee "${CA_PATH}" >/dev/null
sudo -H -n update-ca-certificates >/dev/null
test -s "${CA_PATH}"
printf 'trusted_ca=%s\n' "${CA_PATH}"
''';
  await _runRequiredVmScript(
    script,
    description: 'Trust disposable Caddy internal CA for public health E2E',
  );
}

Future<void> _verifyRemovedCaddyRouteInsideVm({
  required String projectSlug,
}) async {
  const script = r'''
set -eu
SITE_FILE="/opt/deploydash/stack/http/caddy/conf.d/20-${PROJECT_SLUG}.caddy"
MARKER="/tmp/deploydash-e2e-caddy-fault-${PROJECT_SLUG}.marker"
LOG_FILE="/tmp/deploydash-e2e-caddy-fault-${PROJECT_SLUG}.log"
[ -f "${MARKER}" ]
[ ! -e "${SITE_FILE}" ]
sudo -H -n docker exec deploydash_caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
printf 'injected=1\n'
printf 'route_present=0\n'
printf 'fault_log=%s\n' "${LOG_FILE}"
''';
  await _runRequiredVmScript(
    script,
    description: 'Verify failed first-release Caddy cleanup',
    environment: <String, String>{'PROJECT_SLUG': projectSlug},
  );
}

Future<void> _verifyRestoredCaddyRouteInsideVm({
  required String projectSlug,
  required String domain,
}) async {
  const script = r'''
set -eu
SITE_FILE="/opt/deploydash/stack/http/caddy/conf.d/20-${PROJECT_SLUG}.caddy"
[ -f "${SITE_FILE}" ]
grep -F "${DOMAIN}" "${SITE_FILE}" >/dev/null
sudo -H -n docker exec deploydash_caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN}" http://127.0.0.1/)"
case "${CODE}" in
  2*|3*) ;;
  *)
    echo "The retry route returned HTTP ${CODE}." >&2
    exit 1
    ;;
esac
printf 'route_present=1\n'
printf 'http_status=%s\n' "${CODE}"
''';
  await _runRequiredVmScript(
    script,
    description: 'Verify successful retry Caddy route',
    environment: <String, String>{
      'PROJECT_SLUG': projectSlug,
      'DOMAIN': domain,
    },
  );
}

Future<void> _verifyWorkerRuntimeInsideVm({
  required String projectSlug,
  required String workerId,
  required String expectedCommand,
}) async {
  const script = r'''
set -eu
CONTAINER="$(sudo -H -n docker ps -aq \
  --filter 'label=deploydash.managed=true' \
  --filter "label=deploydash.project=${PROJECT_SLUG}" \
  --filter 'label=deploydash.role=worker' \
  --filter "label=deploydash.worker_id=${WORKER_ID}" \
  --filter 'label=deploydash.live=true' | head -n1)"
[ -n "${CONTAINER}" ]
assert_worker_running() {
  [ "$(sudo -H -n docker inspect -f '{{.State.Status}}' "${CONTAINER}")" = running ]
  [ "$(sudo -H -n docker inspect -f '{{.RestartCount}}' "${CONTAINER}")" = 0 ]
}
assert_worker_running
[ "$(sudo -H -n docker inspect -f '{{json .Config.Entrypoint}}' "${CONTAINER}")" = '["/bin/sh"]' ]
sudo -H -n docker inspect -f '{{json .Config.Cmd}}' "${CONTAINER}" | grep -F -- "${EXPECTED_COMMAND}" >/dev/null
sleep 3
assert_worker_running
printf 'container=%s\n' "$(sudo -H -n docker inspect -f '{{.Name}}' "${CONTAINER}" | sed 's#^/##')"
printf 'entrypoint=%s\n' "$(sudo -H -n docker inspect -f '{{json .Config.Entrypoint}}' "${CONTAINER}")"
printf 'command=%s\n' "$(sudo -H -n docker inspect -f '{{json .Config.Cmd}}' "${CONTAINER}")"
printf 'state=%s\n' "$(sudo -H -n docker inspect -f '{{.State.Status}}' "${CONTAINER}")"
printf 'restart_count=%s\n' "$(sudo -H -n docker inspect -f '{{.RestartCount}}' "${CONTAINER}")"
''';
  await _runRequiredVmScript(
    script,
    description: 'Worker runtime verification',
    environment: <String, String>{
      'PROJECT_SLUG': projectSlug,
      'WORKER_ID': workerId,
      'EXPECTED_COMMAND': expectedCommand,
    },
  );
}

Future<void> _installLegacySchedulerWrapperInsideVm({
  required String projectSlug,
  required String taskId,
}) async {
  const script = r'''
set -eu
SCRIPT="/opt/deploydash/state/scheduler/deploydash-${PROJECT_SLUG}-${TASK_ID}.sh"
[ -f "${SCRIPT}" ]
LEGACY_CONTAINER="deploydash_app_${PROJECT_SLUG}"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  "exec /usr/bin/docker exec ${LEGACY_CONTAINER} /bin/sh -lc 'php -v'" \
  | sudo -H -n tee "${SCRIPT}" >/dev/null
sudo -H -n chmod 0755 "${SCRIPT}"
sudo -H -n grep -F "exec /usr/bin/docker exec ${LEGACY_CONTAINER}" "${SCRIPT}" >/dev/null
printf 'legacy_wrapper=%s\n' "${SCRIPT}"
''';
  await _runRequiredVmScript(
    script,
    description: 'Legacy scheduler wrapper fixture',
    environment: <String, String>{
      'PROJECT_SLUG': projectSlug,
      'TASK_ID': taskId,
    },
  );
}

Future<void> _verifySchedulerWrapperRepairInsideVm({
  required String projectSlug,
  required String taskId,
}) async {
  const script = r'''
set -eu
BASE="deploydash-${PROJECT_SLUG}-${TASK_ID}"
SCRIPT="/opt/deploydash/state/scheduler/${BASE}.sh"
SERVICE="${BASE}.service"
LEGACY_CONTAINER="deploydash_app_${PROJECT_SLUG}"
sudo -H -n grep -F 'LIVE_CONTAINER=' "${SCRIPT}" >/dev/null
if sudo -H -n grep -F "exec /usr/bin/docker exec ${LEGACY_CONTAINER}" "${SCRIPT}" >/dev/null; then
  echo 'The scheduler wrapper still targets the legacy container.' >&2
  exit 1
fi
[ "$(sudo -H -n systemctl show "${SERVICE}" -p Result --value)" = success ]
[ "$(sudo -H -n systemctl show "${SERVICE}" -p ExecMainStatus --value)" = 0 ]
sudo -H -n journalctl -u "${SERVICE}" -n 80 --no-pager -o cat | grep -F 'PHP ' >/dev/null
printf 'repaired_wrapper=%s\n' "${SCRIPT}"
printf 'service_result=success\n'
printf 'command_output=PHP version reported\n'
''';
  await _runRequiredVmScript(
    script,
    description: 'Scheduler wrapper repair verification',
    environment: <String, String>{
      'PROJECT_SLUG': projectSlug,
      'TASK_ID': taskId,
    },
  );
}

Future<void> _verifyBaselineStackInsideVm() async {
  if (!_useSshVmTransport && _vmName.trim().isEmpty) {
    return;
  }
  const description = 'VM baseline stack verification';
  final prefix = await _vmShellPrefix(description: description);
  final target = _vmTargetLabel();
  final script = r'''
set -eu
command -v docker >/dev/null
sudo -H -n docker version --format '{{.Server.Version}}' >/dev/null
command -v railpack >/dev/null
railpack --version >/dev/null
systemctl is-active --quiet fail2ban
systemctl is-enabled --quiet fail2ban
sudo -H -n fail2ban-client ping >/dev/null
sudo -H -n fail2ban-client status sshd >/dev/null
for package_name in auditd sysstat unattended-upgrades; do
  dpkg-query -W -f='${Status}' "${package_name}" | grep -Fx 'install ok installed' >/dev/null
done
grep -Fq 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
''';
  final result = await Process.run(
    prefix.first,
    <String>[...prefix.skip(1), 'bash', '-lc', script],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(minutes: 3));
  if (result.exitCode != 0) {
    fail(
      'VM baseline stack verification failed on $target.\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  _pass('Remote Server Stack Verification::Docker install via setup');
  _pass('Remote Server Stack Verification::Railpack install via setup');
  _pass('Remote Server Stack Verification::Fail2ban status and behavior');
  _pass(
    'Remote Server Stack Verification::Auditd/sysstat/unattended-upgrades status',
  );
}
