import 'dart:convert';

import '../../domain/server.dart';

/// The newest envelope written to saved-server JSON configuration columns.
const int currentServerConfigJsonVersion = 1;

/// Owns serialization for the non-relational configuration values on [Servers].
///
/// Existing unversioned JSON objects are V0. They remain readable, but every
/// write uses the explicit V1 envelope defined below.
abstract final class ServerConfigJsonCodecs {
  /// Codec for the saved web-server (Caddy) configuration column.
  static const webServer = _VersionedServerConfigCodec<ServerWebServerConfig>(
    fromPayload: ServerWebServerConfig.fromJsonMap,
    toPayload: _webServerPayload,
  );

  /// Codec for the saved managed-PostgreSQL configuration column.
  static const postgres = _VersionedServerConfigCodec<ServerPostgresConfig>(
    fromPayload: ServerPostgresConfig.fromJsonMap,
    toPayload: _postgresPayload,
  );

  /// Codec for the saved firewall configuration column.
  static const firewall = _VersionedServerConfigCodec<ServerFirewallConfig>(
    fromPayload: ServerFirewallConfig.fromJsonMap,
    toPayload: _firewallPayload,
  );

  /// Codec for the saved system-settings column, such as automatic updates.
  static const system = _VersionedServerConfigCodec<ServerSystemConfig>(
    fromPayload: ServerSystemConfig.fromJsonMap,
    toPayload: _systemPayload,
  );

  /// Codec for the saved managed-software status column: which pinned
  /// versions this server is currently running.
  static const managedSoftware =
      _VersionedServerConfigCodec<ServerManagedSoftwareStatus>(
        fromPayload: ServerManagedSoftwareStatus.fromJsonMap,
        toPayload: _managedSoftwarePayload,
      );

  static Map<String, dynamic> _webServerPayload(ServerWebServerConfig value) =>
      value.toJsonMap();

  static Map<String, dynamic> _postgresPayload(ServerPostgresConfig value) =>
      value.toJsonMap();

  static Map<String, dynamic> _firewallPayload(ServerFirewallConfig value) =>
      value.toJsonMap();

  static Map<String, dynamic> _systemPayload(ServerSystemConfig value) =>
      value.toJsonMap();

  static Map<String, dynamic> _managedSoftwarePayload(
    ServerManagedSoftwareStatus value,
  ) => value.toJsonMap();
}

class _VersionedServerConfigCodec<T> {
  const _VersionedServerConfigCodec({
    required this.fromPayload,
    required this.toPayload,
  });

  final T Function(Map<String, dynamic> payload) fromPayload;
  final Map<String, dynamic> Function(T value) toPayload;

  String encode(T value) {
    return jsonEncode(<String, dynamic>{
      'version': currentServerConfigJsonVersion,
      'payload': toPayload(value),
    });
  }

  T decode(String? raw, {required T fallback}) {
    final object = _decodeStoredServerConfigJsonObject(raw);
    if (object == null) {
      return fallback;
    }

    final version = object['version'];
    final payload = version == null
        ? object
        : _versionOnePayload(object, version);
    return payload == null ? fallback : fromPayload(payload);
  }

  Map<String, dynamic>? _versionOnePayload(
    Map<String, dynamic> envelope,
    Object? version,
  ) {
    if (version != currentServerConfigJsonVersion) {
      return null;
    }
    return _stringKeyedMapOrNull(envelope['payload']);
  }
}

Map<String, dynamic>? _decodeStoredServerConfigJsonObject(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  try {
    return _stringKeyedMapOrNull(jsonDecode(raw));
  } on FormatException {
    return null;
  }
}

// D-58 (T-014): left — non-maps yield null where mapFrom yields const {};
// the null disposition is the contract (missed in commit 0, placed here).
Map<String, dynamic>? _stringKeyedMapOrNull(Object? value) {
  if (value is! Map) {
    return null;
  }
  return Map<String, dynamic>.fromEntries(
    value.entries.map((entry) => MapEntry(entry.key.toString(), entry.value)),
  );
}
