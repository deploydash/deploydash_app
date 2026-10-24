import 'dart:convert';
import 'dart:io';

import 'package:ui/data/local/server_config_json_codecs.dart';
import 'package:ui/domain/server.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _readFixture(String version) {
  final file = File('test/fixtures/server_config_codecs/$version.json');
  return Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map);
}

String _rawColumn(Map<String, dynamic> fixture, String column) {
  return jsonEncode(fixture[column]);
}

Map<String, dynamic> _fixtureObject(
  Map<String, dynamic> fixture,
  String field,
) {
  final value = fixture[field];
  if (value is! Map) {
    throw StateError('Fixture field $field must be an object.');
  }
  return Map<String, dynamic>.from(value);
}

void main() {
  final v0 = _readFixture('v0');
  final v1 = _readFixture('v1');

  test('V0 frozen fixtures decode and re-encode as V1', () {
    final webServer = ServerConfigJsonCodecs.webServer.decode(
      _rawColumn(v0, 'service_web_server_config_json'),
      fallback: ServerWebServerConfig.defaults,
    );
    final postgres = ServerConfigJsonCodecs.postgres.decode(
      _rawColumn(v0, 'service_postgres_config_json'),
      fallback: ServerPostgresConfig.defaults,
    );
    final firewall = ServerConfigJsonCodecs.firewall.decode(
      _rawColumn(v0, 'service_firewall_config_json'),
      fallback: ServerFirewallConfig.defaults,
    );
    final system = ServerConfigJsonCodecs.system.decode(
      _rawColumn(v0, 'service_system_config_json'),
      fallback: ServerSystemConfig.defaults,
    );
    final managedSoftware = ServerConfigJsonCodecs.managedSoftware.decode(
      _rawColumn(v0, 'managed_software_status_json'),
      fallback: ServerManagedSoftwareStatus(
        const <String, Map<String, dynamic>>{},
      ),
    );

    expect(
      jsonDecode(ServerConfigJsonCodecs.webServer.encode(webServer)),
      v1['service_web_server_config_json'],
    );
    expect(
      jsonDecode(ServerConfigJsonCodecs.postgres.encode(postgres)),
      v1['service_postgres_config_json'],
    );
    expect(
      jsonDecode(ServerConfigJsonCodecs.firewall.encode(firewall)),
      v1['service_firewall_config_json'],
    );
    expect(
      jsonDecode(ServerConfigJsonCodecs.system.encode(system)),
      v1['service_system_config_json'],
    );
    expect(
      jsonDecode(
        ServerConfigJsonCodecs.managedSoftware.encode(managedSoftware),
      ),
      v1['managed_software_status_json'],
    );
  });

  test('V1 frozen fixtures round-trip without changing their typed values', () {
    final webServerFixture = _fixtureObject(
      v1,
      'service_web_server_config_json',
    );
    final postgresFixture = _fixtureObject(v1, 'service_postgres_config_json');
    final firewallFixture = _fixtureObject(v1, 'service_firewall_config_json');
    final systemFixture = _fixtureObject(v1, 'service_system_config_json');
    final managedSoftwareFixture = _fixtureObject(
      v1,
      'managed_software_status_json',
    );
    final webServer = ServerConfigJsonCodecs.webServer.decode(
      jsonEncode(webServerFixture),
      fallback: ServerWebServerConfig.defaults,
    );
    final postgres = ServerConfigJsonCodecs.postgres.decode(
      jsonEncode(postgresFixture),
      fallback: ServerPostgresConfig.defaults,
    );
    final firewall = ServerConfigJsonCodecs.firewall.decode(
      jsonEncode(firewallFixture),
      fallback: ServerFirewallConfig.defaults,
    );
    final system = ServerConfigJsonCodecs.system.decode(
      jsonEncode(systemFixture),
      fallback: ServerSystemConfig.defaults,
    );
    final managedSoftware = ServerConfigJsonCodecs.managedSoftware.decode(
      jsonEncode(managedSoftwareFixture),
      fallback: ServerManagedSoftwareStatus(
        const <String, Map<String, dynamic>>{},
      ),
    );

    expect(webServer.toJsonMap(), _fixtureObject(webServerFixture, 'payload'));
    expect(postgres.toJsonMap(), _fixtureObject(postgresFixture, 'payload'));
    expect(firewall.toJsonMap(), _fixtureObject(firewallFixture, 'payload'));
    expect(system.toJsonMap(), _fixtureObject(systemFixture, 'payload'));
    expect(
      managedSoftware.toJsonMap(),
      _fixtureObject(managedSoftwareFixture, 'payload'),
    );
  });

  test('malformed and unsupported values use safe defaults', () {
    expect(
      ServerConfigJsonCodecs.webServer
          .decode('{not json}', fallback: ServerWebServerConfig.defaults)
          .toJsonMap(),
      ServerWebServerConfig.defaults.toJsonMap(),
    );
    expect(
      ServerConfigJsonCodecs.postgres
          .decode(
            '{"version":2,"payload":{"postgres_version":"18"}}',
            fallback: ServerPostgresConfig.defaults,
          )
          .toJsonMap(),
      ServerPostgresConfig.defaults.toJsonMap(),
    );
    expect(
      ServerConfigJsonCodecs.managedSoftware
          .decode(
            '{"version":999,"payload":{}}',
            fallback: ServerManagedSoftwareStatus(
              const <String, Map<String, dynamic>>{},
            ),
          )
          .components,
      isEmpty,
    );
  });
}
