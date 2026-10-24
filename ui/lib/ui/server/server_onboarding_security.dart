import '../../providers/server_provider.dart';
import '../../services/managed_ssh_key_service.dart';
import '../../utils/payload_codecs.dart';
import '../../utils/trim_or_null.dart';

bool isHostKeyMismatchMessage(String? message) {
  if (message == null) {
    return false;
  }
  final lowered = message.toLowerCase();
  return (lowered.contains('host key') && lowered.contains('does not match')) ||
      lowered.contains('remote host identification has changed') ||
      lowered.contains('ssh host key error') ||
      lowered.contains('ssh host key mismatch');
}

bool hasHostKeyMismatch(ServerState state) {
  if (state.errorPayload?['host_key_confirmation_required'] == true) {
    return true;
  }
  if (isHostKeyMismatchMessage(state.error)) {
    return true;
  }
  for (final event in state.events) {
    if (isHostKeyMismatchMessage(event['message']?.toString())) {
      return true;
    }
  }
  return false;
}

/// What the two fingerprints are, for the host-key confirmation dialog.
///
/// A record rather than a `Map<String, String>`: every field is present by
/// construction, so the caller reads `details.host` instead of asserting a
/// key exists on a map that this function is the only writer of.
///
/// A fingerprint the backend did not report reads `Not available` rather than
/// blank -- the dialog exists to let the user compare two values, and an empty
/// line invites them to assume the comparison was made.
({String host, String port, String oldFingerprint, String newFingerprint})
hostKeyConfirmationDetails(
  ServerState state, {
  required String fallbackHost,
  required String fallbackPort,
}) {
  final raw = state.errorPayload?['host_key_mismatch'];
  final mismatch = mapFrom(raw);
  String fingerprint(String key) {
    final value = mismatch[key]?.toString().trim() ?? '';
    return value.isEmpty ? 'Not available' : value;
  }

  return (
    host: mismatch['host']?.toString() ?? fallbackHost,
    port: mismatch['port']?.toString() ?? fallbackPort,
    oldFingerprint: fingerprint('old_fingerprint'),
    newFingerprint: fingerprint('new_fingerprint'),
  );
}

/// Rebuilds the bootstrap draft for a setup retry from the saved record.
///
/// The record holds the identity; the resolved connection payload holds the
/// secret the first attempt saved. A retry that cannot resolve a payload
/// never reaches this builder -- the wizard reports incomplete credentials
/// instead of provisioning against a guessed identity.
ServerDraft buildRetryBootstrapDraft({
  required Server server,
  required Map<String, dynamic> connectionPayload,
}) {
  return ServerDraft(
    name: server.name,
    host: server.host,
    port: server.port,
    sshUser: server.sshUser,
    authMethod: server.authMethod,
    sshPassword: trimOrNull(connectionPayload['password']?.toString()),
    privateKey: trimOrNull(connectionPayload['private_key']?.toString()),
  );
}

ServerDraft buildManagedDraft({
  required ServerDraft bootstrapDraft,
  required ManagedSshKeyPair managedKeyPair,
}) {
  // The three nulls are the auth-method switch: bootstrap secrets must not
  // cross into the managed draft (a sentinel default would preserve them).
  return bootstrapDraft.copyWith(
    sshUser: 'ubuntu',
    authMethod: ServerAuthMethod.sshKey,
    sshPassword: null,
    keyPath: null,
    privateKey: managedKeyPair.privateKey,
    publicKey: managedKeyPair.publicKey,
    managedUserPassword: null,
  );
}

Map<String, dynamic> buildManagedConnectionPayload(ServerDraft managedDraft) {
  return <String, dynamic>{
    'username': managedDraft.sshUser,
    'port': managedDraft.port,
    if (managedDraft.privateKey != null) 'private_key': managedDraft.privateKey,
  };
}

Map<String, dynamic> buildManagedSetupSettings({
  required ServerDraft bootstrapDraft,
  required ServerDraft managedDraft,
}) {
  return <String, dynamic>{
    // admin_user is server-owned (T-1.4.8); omitted rather than sent.
    'hostname': bootstrapDraft.name,
    'timezone': 'UTC',
    'ssh_public_key': managedDraft.publicKey,
    'disable_password_auth': true,
    'disable_root_login': true,
    'ssh_banner_text': 'Authorized uses only.',
  };
}

/// Reads the managed account password out of a setup result, if one is there.
///
/// Setup returns `managed_user_password` only when it generated one --
/// bootstrapping as somebody other than the managed user (#62) -- so every
/// other shape reads as absent rather than as an error.
String? managedUserPasswordFromSetupResult(Map<String, dynamic>? setupResult) {
  final value = setupResult?['managed_user_password'];
  if (value is! String) {
    return null;
  }
  return trimOrNull(value);
}

ServerDraft buildSavedManagedDraft({
  required ServerDraft managedDraft,
  required Map<String, dynamic>? managedConnectionResult,
  String? managedUserPassword,
}) {
  // managedUserPassword is spelled (not defaulted) so the builder's own
  // parameter — including its null default — wins over the draft's value,
  // exactly as the fresh construction did.
  return managedDraft.copyWith(
    port: (managedConnectionResult?['port'] as int?) ?? managedDraft.port,
    sshUser:
        managedConnectionResult?['username']?.toString() ??
        managedDraft.sshUser,
    authMethod: ServerAuthMethod.sshKey,
    managedUserPassword: managedUserPassword,
  );
}
