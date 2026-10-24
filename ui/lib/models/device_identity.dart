/// Stable identity for this desktop installation.
///
/// Written once to `device_identity.json` beside the encrypted database and
/// read back on every launch, so it survives reinstalls of the app but not of
/// the machine. It identifies the *installation*, never the person using it.
class DeviceIdentity {
  /// Creates an identity with its generated [id] and first-seen [createdAt].
  const DeviceIdentity({required this.id, required this.createdAt});

  /// Opaque installation identifier, generated on first launch.
  final String id;

  /// When this installation first generated its identity.
  final DateTime createdAt;
}
