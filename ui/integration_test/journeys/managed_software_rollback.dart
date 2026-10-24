part of '../e2e_checklist_test.dart';

Future<void> _runManagedSoftwareRollbackScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  binding.shouldPropagateDevicePointerEvents = false;
  await _ensurePostgresServiceEnabled(tester);
  await _ensureHttpGatewayEnabled(tester);
  await _prepareManagedSoftwareFixtures();
  await _openHome(tester);
  await _openServerManagementFromHome(tester);
  await _tap(tester, const Key('server-management-nav-updates'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-updates-tab')),
    description: 'managed software updates',
    timeout: const Duration(minutes: 2),
  );

  await _exerciseManagedComponentUpdateRollback(
    tester,
    componentId: 'http_gateway',
    verificationAfterUpdate:
        "grep -F 'image: caddy:2.11.2-alpine' /opt/deploydash/stack/http/docker-compose.yml\n"
        "docker exec deploydash_caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile",
    verificationAfterRollback:
        "grep -F 'image: caddy:2.10.2-alpine' /opt/deploydash/stack/http/docker-compose.yml\n"
        "docker inspect -f '{{.State.Running}}' deploydash_caddy | grep -Fx true",
  );
  _pass(
    'Server Management::Caddy update/rollback',
    'Updated the real Caddy compose service, then restored and started its previous image snapshot.',
  );

  await _exerciseManagedComponentUpdateRollback(
    tester,
    componentId: 'dns_service',
    verificationAfterUpdate:
        "grep -F 'image: internetsystemsconsortium/bind9:9.20' /opt/deploydash/stack/dns/docker-compose.yml\n"
        'docker exec deploydash_bind9 named-checkconf /etc/bind/named.conf',
    verificationAfterRollback:
        "grep -F 'image: internetsystemsconsortium/bind9:9.18' /opt/deploydash/stack/dns/docker-compose.yml\n"
        "docker inspect -f '{{.State.Running}}' deploydash_bind9 | grep -Fx true",
  );
  _pass(
    'Server Management::BIND update/rollback',
    'Updated and rolled back a running BIND service while retaining valid named configuration.',
  );

  await _exerciseManagedComponentUpdateRollback(
    tester,
    componentId: 'walg_backup_tool',
    verificationAfterUpdate: "wal-g --version | grep -F 'v3.0.8'",
    verificationAfterRollback: "wal-g --version | grep -F 'v3.0.7'",
  );
  _pass(
    'Server Management::WAL-G update/rollback',
    'Installed the pinned WAL-G release and restored the previous real binary snapshot.',
  );

  await _verifyPostgresCommand(
    databaseName: 'postgres',
    sql:
        "CREATE TABLE IF NOT EXISTS e2e_managed_rollback(value text); "
        "TRUNCATE e2e_managed_rollback; "
        "INSERT INTO e2e_managed_rollback VALUES ('preserved')",
  );
  await _exerciseManagedComponentUpdateRollback(
    tester,
    componentId: 'postgresql_database_service',
    verificationAfterUpdate:
        "grep -F 'image: deploydash/postgres-ext:17.10-bookworm-base' /opt/deploydash/stack/postgres/docker-compose.yml\n"
        "docker exec deploydash_postgres pg_isready -U deploydash -d postgres",
    verificationAfterRollback:
        "grep -F 'image: deploydash/postgres-ext:17-bookworm-base' /opt/deploydash/stack/postgres/docker-compose.yml\n"
        "docker exec deploydash_postgres psql -U deploydash postgres -Atc \"SELECT value FROM e2e_managed_rollback\" | grep -Fx preserved",
  );
  _pass(
    'Server Management::PostgreSQL managed update/rollback',
    'Used the guarded dump/restore rollback and recovered the pre-update PostgreSQL sentinel data.',
  );

  await _exerciseManagedComponentUpdateRollback(
    tester,
    componentId: 'railpack_build_system',
    verificationAfterUpdate: "railpack --version | grep -F '0.29.0'",
    verificationAfterRollback: "railpack --version | grep -F '0.28.0'",
  );
  _pass(
    'Server Management::Railpack update/reconcile',
    'Reconciled Railpack to the pinned contract and restored the previous CLI snapshot.',
  );

  await _seedUnavailableDockerRollback();
  await _tap(tester, const Key('server-updates-refresh-tooling'));
  await _openManagedCapability(tester, 'docker_runtime');
  final beforeDocker = await _runRequiredVmScript(
    'docker version --format "{{.Server.Version}}"',
    description: 'Docker version before guarded rollback',
    sudo: true,
  );
  await _tap(tester, const Key('server-updates-rollback-docker_runtime'));
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Rollback'),
    description: 'confirm guarded Docker rollback',
  );
  await _waitFor(
    tester,
    find.text('Update failed'),
    description: 'unavailable Docker rollback refusal',
    timeout: const Duration(minutes: 3),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'OK'),
    description: 'acknowledge guarded Docker rollback refusal',
  );
  final afterDocker = await _runRequiredVmScript(
    'docker version --format "{{.Server.Version}}"\n'
    "test -z \"\$(docker ps --filter label=deploydash.managed=true --filter status=exited -q)\"",
    description: 'Docker unchanged after guarded rollback refusal',
    sudo: true,
  );
  expect(
    afterDocker.stdout.toString().split('\n').first.trim(),
    beforeDocker.stdout.toString().trim(),
  );
  _pass(
    'Server Management::Docker package update/rollback guard',
    'Refused unavailable exact apt versions and left Docker plus managed containers running.',
  );
}

Future<void> _ensureHttpGatewayEnabled(WidgetTester tester) async {
  await _openHome(tester);
  await _openServerManagementFromHome(tester);
  await _tap(tester, const Key('server-management-nav-services'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-services-tab')),
    description: 'server services for HTTP gateway',
  );
  final enabledRow = find.byKey(const Key('service-row-proxy'));
  if (enabledRow.evaluate().isEmpty) {
    await _tap(tester, const Key('service-enable-proxy'));
    await _waitFor(
      tester,
      enabledRow,
      description: 'enabled HTTP gateway',
      timeout: const Duration(minutes: 8),
    );
  }
}

Future<void> _prepareManagedSoftwareFixtures() async {
  const script = r'''set -eu

# Caddy: use a real previous upstream image.
docker pull caddy:2.10.2-alpine >/dev/null
sed -i -E 's#image: caddy:[^ ]+#image: caddy:2.10.2-alpine#' /opt/deploydash/stack/http/docker-compose.yml
docker compose -f /opt/deploydash/stack/http/docker-compose.yml up -d --remove-orphans
docker exec deploydash_caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# BIND: create a valid disposable managed stack on the previous production line.
mkdir -p /opt/deploydash/stack/dns/bind /opt/deploydash/stack/dns/zones
cat >/opt/deploydash/stack/dns/bind/named.conf <<'EOF'
options {
  directory "/var/cache/bind";
  recursion no;
  listen-on { any; };
  listen-on-v6 { none; };
};
EOF
cat >/opt/deploydash/stack/dns/docker-compose.yml <<'EOF'
services:
  bind9:
    container_name: deploydash_bind9
    image: internetsystemsconsortium/bind9:9.18
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETUID
      - SETGID
    pids_limit: 512
    command: ["-g", "-c", "/etc/bind/named.conf"]
    volumes:
      - /opt/deploydash/stack/dns/bind:/etc/bind:ro
      - /opt/deploydash/stack/dns/zones:/var/lib/bind/zones:ro
EOF
docker compose -f /opt/deploydash/stack/dns/docker-compose.yml up -d --remove-orphans
sleep 2
docker exec deploydash_bind9 named-checkconf /etc/bind/named.conf

# WAL-G: install the previous real release asset selected from GitHub metadata.
WALG_TMP="$(mktemp -d)"
trap 'rm -rf "${WALG_TMP}"' EXIT
curl -fsSL https://api.github.com/repos/wal-g/wal-g/releases/tags/v3.0.7 -o "${WALG_TMP}/release.json"
WALG_URL="$(python3 - "${WALG_TMP}/release.json" <<'PY'
import json, sys
for asset in json.load(open(sys.argv[1], encoding='utf-8')).get('assets', []):
    name = asset.get('name', '').lower()
    if 'pg' in name and 'amd64' in name and name.endswith('.tar.gz'):
        print(asset['browser_download_url'])
        break
PY
)"
[ -n "${WALG_URL}" ]
curl -fsSL "${WALG_URL}" -o "${WALG_TMP}/wal-g.tar.gz"
tar -xzf "${WALG_TMP}/wal-g.tar.gz" -C "${WALG_TMP}"
WALG_BIN="$(find "${WALG_TMP}" -type f -name 'wal-g*' ! -name '*.tar.gz' | head -n1)"
install -m 0755 "${WALG_BIN}" /usr/local/bin/wal-g
wal-g --version | grep -F v3.0.7

# PostgreSQL: retain the real current image under the supported legacy tag.
PG_COMPOSE=/opt/deploydash/stack/postgres/docker-compose.yml
PG_CURRENT="$(awk '/^[[:space:]]*image:/ {print $2; exit}' "${PG_COMPOSE}")"
docker tag "${PG_CURRENT}" deploydash/postgres-ext:17-bookworm-base
sed -i -E '0,/image:/{s#image: .*#image: deploydash/postgres-ext:17-bookworm-base#}' "${PG_COMPOSE}"
docker compose -f "${PG_COMPOSE}" up -d --remove-orphans
docker exec deploydash_postgres pg_isready -U deploydash -d postgres

# Railpack: install the previous real release CLI.
RAILPACK_TMP="$(mktemp -d)"
curl -fsSL https://api.github.com/repos/railwayapp/railpack/releases/tags/v0.28.0 -o "${RAILPACK_TMP}/release.json"
RAILPACK_URL="$(python3 - "${RAILPACK_TMP}/release.json" <<'PY'
import json, sys
for asset in json.load(open(sys.argv[1], encoding='utf-8')).get('assets', []):
    name = asset.get('name', '')
    if 'x86_64-unknown-linux-musl' in name and name.endswith('.tar.gz'):
        print(asset['browser_download_url'])
        break
PY
)"
[ -n "${RAILPACK_URL}" ]
curl -fsSL "${RAILPACK_URL}" -o "${RAILPACK_TMP}/railpack.tar.gz"
tar -xzf "${RAILPACK_TMP}/railpack.tar.gz" -C "${RAILPACK_TMP}" railpack
install -m 0755 "${RAILPACK_TMP}/railpack" /usr/local/bin/railpack
railpack --version | grep -F 0.28.0
''';
  await _runRequiredVmScript(
    script,
    description: 'managed software previous-version fixtures',
    timeout: const Duration(minutes: 15),
    sudo: true,
  );
}

Future<void> _exerciseManagedComponentUpdateRollback(
  WidgetTester tester, {
  required String componentId,
  required String verificationAfterUpdate,
  required String verificationAfterRollback,
}) async {
  await _tap(tester, const Key('server-updates-refresh-tooling'));
  await _openManagedCapability(tester, componentId);
  final updateKey = Key('server-updates-update-$componentId');
  await _waitForEnabledButton(
    tester,
    updateKey,
    description: '$componentId update',
    timeout: const Duration(minutes: 3),
  );
  await _tap(tester, updateKey);
  final rollbackKey = Key('server-updates-rollback-$componentId');
  await _waitForEnabledButton(
    tester,
    rollbackKey,
    description: '$componentId rollback after update',
    timeout: const Duration(minutes: 20),
  );
  await _runRequiredVmScript(
    verificationAfterUpdate,
    description: '$componentId update verification',
    timeout: const Duration(minutes: 4),
    sudo: true,
  );
  await _tap(tester, rollbackKey);
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Rollback'),
    description: 'confirm $componentId rollback',
  );
  await _waitFor(
    tester,
    find.text('Managed server software rollback completed.'),
    description: '$componentId rollback completion',
    timeout: const Duration(minutes: 20),
  );
  await _runRequiredVmScript(
    verificationAfterRollback,
    description: '$componentId rollback verification',
    timeout: const Duration(minutes: 5),
    sudo: true,
  );
}

Future<void> _openManagedCapability(
  WidgetTester tester,
  String componentId,
) async {
  final capability = find.byKey(Key('server-updates-capability-$componentId'));
  await _waitFor(
    tester,
    capability,
    description: '$componentId update capability',
    timeout: const Duration(minutes: 3),
  );
  await tester.ensureVisible(capability);
  await tester.pumpAndSettle();
  final update = find.byKey(Key('server-updates-update-$componentId'));
  if (update.evaluate().isEmpty) {
    await tester.tap(capability, warnIfMissed: false);
    await tester.pumpAndSettle();
  }
}

Future<void> _seedUnavailableDockerRollback() async {
  const script = r'''python3 - <<'PY'
import json
import pathlib
from datetime import datetime, timezone

path = pathlib.Path('/opt/deploydash/state/managed-software-ledger.json')
payload = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {'schema_version': 1, 'components': {}}
payload.setdefault('components', {})['docker_runtime'] = {
    'component_id': 'docker_runtime',
    'installed_version': 'unavailable-e2e-version',
    'previous_version': 'unavailable-e2e-version',
    'target_version': 'current',
    'last_action': 'update',
    'status': 'success',
    'changed_at': datetime.now(timezone.utc).isoformat(),
    'package_versions': {
        'docker-ce': '0:0.0.0-e2e-unavailable',
        'docker-ce-cli': '0:0.0.0-e2e-unavailable',
        'containerd.io': '0.0.0-e2e-unavailable',
        'docker-compose-plugin': '0.0.0-e2e-unavailable',
    },
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, separators=(',', ':')), encoding='utf-8')
path.chmod(0o600)
PY
''';
  await _runRequiredVmScript(
    script,
    description: 'unavailable Docker rollback fixture',
    sudo: true,
  );
}

Future<void> _startRepositoryDeploy(WidgetTester tester) async {
  // Repository host-key recovery retries into the same disposable Caddy
  // fixture as the regular deployment E2E paths. Keep the application's
  // public-health probe strict and trust only that fixture's local CA in the
  // VM before a retry can reach routed health validation.
  await _trustCaddyInternalCaInsideVm();
  await _scrollProjectTabTo(tester, const Key('github-deploy-button'));
  await _waitForEnabledButton(
    tester,
    const Key('github-deploy-button'),
    description: 'repository deploy action',
    timeout: const Duration(minutes: 2),
  );
  await _tap(tester, const Key('github-deploy-button'));
}
