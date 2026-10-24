import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/local/app_database.dart';
import '../data/local/device_installation_repository.dart';
import 'app_analytics_service.dart';
import 'device_identity_service.dart';

/// The update-check protocol version this client speaks.
///
/// Sent with every request and echoed in the signed response.
const int desktopUpdateProtocolVersion = 1;

/// The local database schema version reported to the update service.
///
/// Derived from the database's own constant rather than restated. This was a
/// second hardcoded copy of the number: it is sent as `database_schema` and
/// compared against a release's `minimum_schema`/`maximum_schema`, so a
/// drifted copy would not fail loudly -- it would make the update service
/// quietly stop offering updates. An equality test guards the unification so
/// that a future re-duplication is caught immediately.
const int desktopDatabaseSchemaVersion = appDatabaseSchemaVersion;

/// Which release channel this build follows.
const String desktopUpdateChannel = String.fromEnvironment(
  'DEPLOYDASH_RELEASE_CHANNEL',
  defaultValue: 'stable',
);

/// How this build was installed -- `deb`, `snap`, `flatpak`, `dmg`,
/// `mac_app_store`, `windows_store`, or `development`.
///
/// Decides which install strategy a release is allowed to offer. A Snap build
/// must never be handed an apt URI, so a mismatch is rejected rather than
/// followed.
const String desktopDistribution = String.fromEnvironment(
  'DEPLOYDASH_DISTRIBUTION',
  defaultValue: 'development',
);

/// The update service this build asks.
const String desktopUpdateEndpoint = String.fromEnvironment(
  'DEPLOYDASH_UPDATE_ENDPOINT',
  defaultValue: 'https://updates.deploydash.com/v1/desktop/releases/check',
);

/// The version to report when the platform cannot supply package info.
const String desktopReleaseVersion = String.fromEnvironment(
  'DEPLOYDASH_RELEASE_VERSION',
  defaultValue: 'development',
);

/// The build number to report when the platform cannot supply package info.
const String desktopReleaseBuild = String.fromEnvironment(
  'DEPLOYDASH_RELEASE_BUILD',
);

/// The exact URI a Windows Store install must point at.
///
/// Compared literally rather than by scheme, because this one names the
/// product page Deploy Dash is published on -- an `ms-windows-store:` URI that
/// merely parses could send the user to install something else.
const String desktopWindowsStoreInstallUri =
    'ms-windows-store://pdp/?productid=9P1GK6Z58B9T';

/// The Ed25519 keys whose signatures this build accepts, by key id.
///
/// A response signed by anything else is refused. This map is the whole root
/// of trust for updates: everything else in the manifest is only believed
/// because a key in here vouched for it.
const Map<String, String> desktopUpdateTrustedPublicKeys = <String, String>{
  'desktop-release-2026-01': 'iRWhbsGVzAOFnYkhCl7Gj18vcQxFviLlxELqtm162dQ=',
};

/// What the last update check concluded.
enum DesktopUpdateStatus {
  /// No check has run in this session.
  notChecked,

  /// This build is the newest for its channel.
  current,

  /// A newer build exists and can be installed.
  updateAvailable,

  /// This build is below the minimum supported version. The user should be
  /// told plainly rather than merely nudged.
  updateRequired,

  /// This installation can no longer be served -- an unsupported platform,
  /// architecture or distribution.
  unsupported,

  /// A release exists, but this installation is not in its rollout yet.
  ///
  /// Deliberately not [current]: nothing is wrong and nothing is available,
  /// and saying "up to date" would be untrue.
  deferred,

  /// The check itself failed. The message says why.
  failed,
}

/// How much a release matters, which decides how insistently it is surfaced.
enum DesktopUpdateSeverity {
  /// An ordinary release.
  normal,

  /// Worth taking soon.
  recommended,

  /// Fixes a security problem.
  security,

  /// Should be installed now.
  critical,
}

/// How an update is installed on this platform.
///
/// Deploy Dash never downloads and runs an installer itself. Each strategy
/// hands off to the platform's own updater -- apt, snapd, Flatpak, Sparkle, or
/// a store -- so the code that installs a signed binary is the one the OS
/// already trusts.
enum DesktopUpdateInstallStrategy {
  /// The Deploy Dash apt repository, for `.deb` installs.
  aptRepository,

  /// The Snap Store.
  snap,

  /// Flathub or another Flatpak remote.
  flatpak,

  /// Sparkle, for direct macOS DMG installs.
  sparkle,

  /// The Mac App Store.
  macAppStore,

  /// The Microsoft Store.
  windowsStore,
}

/// The running build's version and build number.
class DesktopBuildInfo {
  /// Records one build's identity.
  const DesktopBuildInfo({required this.version, required this.build});

  /// The marketing version, e.g. `1.4.2`.
  final String version;

  /// The build number, monotonic within a version. May be empty for a
  /// development build.
  final String build;

  /// `version+build`, or just the version when there is no build number.
  String get displayVersion =>
      build.trim().isEmpty ? version : '$version+$build';
}

/// Everything the update service is told about this installation.
///
/// No user data, no project or server information -- platform, architecture,
/// how it was installed, which channel, and what versions it is running. The
/// service echoes these back inside the signed payload, and
/// [DesktopUpdateService] refuses a response whose echo does not match, so a
/// signed answer meant for a different installation cannot be replayed at this
/// one.
class DesktopUpdateRequest {
  /// Records the facts one check reports.
  const DesktopUpdateRequest({
    required this.platform,
    required this.architecture,
    required this.distribution,
    required this.channel,
    required this.version,
    required this.build,
    required this.databaseSchema,
    required this.protocol,
  });

  /// The operating system.
  final String platform;

  /// The CPU architecture.
  final String architecture;

  /// How this build was installed. See [desktopDistribution].
  final String distribution;

  /// The release channel being followed.
  final String channel;

  /// The running version.
  final String version;

  /// The running build number.
  final String build;

  /// The local database schema version, so a release that cannot read it is
  /// not offered.
  final int databaseSchema;

  /// The protocol version being spoken.
  final int protocol;

  /// These facts as the request's query string.
  ///
  /// The same map is compared against the signed response's echo, so the two
  /// cannot drift apart.
  Map<String, String> get queryParameters => <String, String>{
    'platform': platform,
    'architecture': architecture,
    'distribution': distribution,
    'channel': channel,
    'version': version,
    'build': build,
    'database_schema': '$databaseSchema',
    'protocol': '$protocol',
  };
}

/// One release the update service is offering, after its signature verified.
///
/// Every field here came out of a payload signed by a key in
/// [desktopUpdateTrustedPublicKeys] and was range-checked while parsing. An
/// instance existing means the manifest was trustworthy -- not that the
/// release applies to this installation, which the caller still decides.
class DesktopUpdateRelease {
  /// Records one verified release. Built by parsing a signed payload.
  const DesktopUpdateRelease({
    required this.releaseId,
    required this.version,
    required this.build,
    required this.publishedAt,
    required this.severity,
    required this.title,
    required this.summary,
    required this.releaseNotesUri,
    required this.minimumSupportedVersion,
    required this.minimumSupportedBuild,
    required this.minimumDatabaseSchema,
    required this.maximumDatabaseSchema,
    required this.rolloutPercentage,
    required this.rolloutSalt,
    required this.installStrategy,
    required this.installUri,
    this.artifactSha256,
    this.artifactSize,
  });

  /// The release's stable id. What a dismissal is remembered against.
  final String releaseId;

  /// The version being offered.
  final String version;

  /// The build number being offered.
  final String build;

  /// When it was published, in UTC.
  final DateTime publishedAt;

  /// How much it matters.
  final DesktopUpdateSeverity severity;

  /// The release's headline.
  final String title;

  /// One paragraph on what changed.
  final String summary;

  /// Where the full notes live. Always HTTPS.
  final Uri releaseNotesUri;

  /// The oldest version this release can be installed over.
  final String minimumSupportedVersion;

  /// The oldest build this release can be installed over.
  final String minimumSupportedBuild;

  /// The oldest local database schema this release can read.
  final int minimumDatabaseSchema;

  /// The newest local database schema this release can read.
  ///
  /// Both bounds are enforced before the release is offered: installing a
  /// build that cannot open the user's existing database would look like data
  /// loss.
  final int maximumDatabaseSchema;

  /// What share of installations this release has been opened to, 0-100.
  final int rolloutPercentage;

  /// The per-release salt that makes rollout membership stable and
  /// unguessable. See [DesktopUpdateService.check].
  final String rolloutSalt;

  /// How this installation would install it.
  final DesktopUpdateInstallStrategy installStrategy;

  /// The URI handed to the platform updater. Its scheme is validated against
  /// [installStrategy], so a store strategy cannot carry an arbitrary link.
  final Uri installUri;

  /// The artifact's SHA-256, when the manifest declared one.
  final String? artifactSha256;

  /// The artifact's size in bytes, when the manifest declared one.
  final int? artifactSize;
}

/// The result of an update check, as the UI reads it.
class DesktopUpdateSnapshot {
  /// Records one check's outcome.
  const DesktopUpdateSnapshot({
    required this.status,
    required this.currentBuild,
    this.release,
    this.checkedAt,
    this.message,
    this.dismissedReleaseId,
  });

  /// The starting state: this build is known, nothing has been checked.
  factory DesktopUpdateSnapshot.notChecked(DesktopBuildInfo build) {
    return DesktopUpdateSnapshot(
      status: DesktopUpdateStatus.notChecked,
      currentBuild: build,
    );
  }

  /// What the check concluded.
  final DesktopUpdateStatus status;

  /// The build that is running.
  final DesktopBuildInfo currentBuild;

  /// The release involved, when there is one. Present for a deferred rollout
  /// too, which is why it is not implied by [status].
  final DesktopUpdateRelease? release;

  /// When the check ran, or null before the first one.
  final DateTime? checkedAt;

  /// A sentence explaining a failure, a deferral, or a service note.
  final String? message;

  /// The release the user has already dismissed, remembered across restarts.
  final String? dismissedReleaseId;

  /// Whether an update is available or required.
  bool get hasUpdate =>
      status == DesktopUpdateStatus.updateAvailable ||
      status == DesktopUpdateStatus.updateRequired;

  /// Whether to draw the update badge.
  ///
  /// A dismissed release stops badging but is still reported by [status] --
  /// dismissing hides the nag, it does not pretend the release is gone.
  bool get showBadge {
    // Hoisted so the `!= null` check promotes it; a public final field is
    // never promoted.
    final release = this.release;
    return hasUpdate &&
        release != null &&
        release.releaseId != dismissedReleaseId;
  }
}

/// One HTTP response from the update service.
class DesktopUpdateHttpResponse {
  /// Records a response.
  const DesktopUpdateHttpResponse({
    required this.statusCode,
    required this.body,
    this.etag,
  });

  /// The HTTP status.
  final int statusCode;

  /// The body, empty for a 304.
  final String body;

  /// The `ETag`, stored so the next check can be conditional.
  final String? etag;
}

/// Performs the update check request. The seam that makes every response
/// status -- 304, 400, 429, 500, a malformed body -- reachable from a unit
/// test.
typedef DesktopUpdateHttpGet =
    Future<DesktopUpdateHttpResponse> Function(Uri uri, {String? etag});

/// Reads the running build's version and build number.
typedef DesktopBuildInfoLoader = Future<DesktopBuildInfo> Function();

/// Opens a URI in the platform's handler.
typedef DesktopUpdateUriLauncher = Future<bool> Function(Uri uri);

/// Starts an install. Overridable so tests never invoke a real updater.
typedef DesktopUpdateInstaller =
    Future<bool> Function(DesktopUpdateRelease release);

const MethodChannel _desktopUpdateChannel = MethodChannel(
  'com.deploydash.desktop/updates',
);

/// An update check could not be completed or could not be trusted.
///
/// Carries a sentence written for the user, because every one of these is
/// shown: a signature that did not verify, a manifest for a different
/// installation, an expired response, a service that was unreachable.
class DesktopUpdateException implements Exception {
  /// Creates the exception with the sentence to show.
  const DesktopUpdateException(this.message);

  /// What went wrong, in the user's terms.
  final String message;

  @override
  String toString() => message;
}

/// Checks for desktop updates, and verifies the answer before believing it.
///
/// The update path is the one place where a remote party can influence what
/// code runs on the user's machine, so the response is treated as hostile
/// until it proves otherwise. Every check requires, in order: a signature from
/// a key in [desktopUpdateTrustedPublicKeys]; a supported envelope and
/// manifest version; a validity window that has not expired; a request echo
/// matching this exact installation; an install strategy matching how this
/// build was installed; and a database compatibility range that includes the
/// local schema. Any one failing aborts the check.
///
/// Installing is then delegated to the platform's own updater -- see
/// [DesktopUpdateInstallStrategy].
class DesktopUpdateService {
  /// Creates the service. The injectable collaborators are what let the
  /// verification failures above be tested individually.
  DesktopUpdateService({
    required DeviceInstallationRepository repository,
    DesktopUpdateHttpGet? httpGet,
    DesktopBuildInfoLoader? loadBuildInfo,
    DesktopUpdateUriLauncher? launchUri,
    DesktopUpdateInstaller? installUpdate,
    Map<String, String> trustedPublicKeys = desktopUpdateTrustedPublicKeys,
    DateTime Function()? clock,
    String endpoint = desktopUpdateEndpoint,
    String distribution = desktopDistribution,
    String channel = desktopUpdateChannel,
  }) : _repository = repository,
       _httpGet = httpGet ?? _defaultHttpGet,
       _loadBuildInfo = loadBuildInfo ?? _defaultLoadBuildInfo,
       _launchUri = launchUri ?? _defaultLaunchUri,
       _installUpdate = installUpdate,
       _trustedPublicKeys = trustedPublicKeys,
       _clock = clock ?? DateTime.now,
       _endpoint = endpoint,
       _distribution = distribution,
       _channel = channel;

  final DeviceInstallationRepository _repository;
  final DesktopUpdateHttpGet _httpGet;
  final DesktopBuildInfoLoader _loadBuildInfo;
  final DesktopUpdateUriLauncher _launchUri;
  final DesktopUpdateInstaller? _installUpdate;
  final Map<String, String> _trustedPublicKeys;
  final DateTime Function() _clock;
  final String _endpoint;
  final String _distribution;
  final String _channel;

  /// The running build's version and build number.
  Future<DesktopBuildInfo> loadBuildInfo() => _loadBuildInfo();

  /// Checks for an update and records the outcome against the installation.
  ///
  /// Conditional on the stored `ETag`: a 304 reuses the cached signed
  /// envelope, which is re-verified rather than trusted for having been
  /// verified before.
  ///
  /// **Never throws.** A failure of any kind -- network, service, signature,
  /// mismatch -- becomes a snapshot with [DesktopUpdateStatus.failed] and a
  /// message, and is still recorded. An update check that threw would be an
  /// update check that could break app startup.
  ///
  /// A release inside its rollout percentage is returned as available; one
  /// outside it comes back [DesktopUpdateStatus.deferred]. Membership is
  /// decided by hashing the release's salt with the device id, so it is stable
  /// across checks -- an installation does not flicker in and out of a rollout
  /// -- and cannot be steered by anyone who does not know the salt.
  Future<DesktopUpdateSnapshot> check({
    required DeviceInstallationRecord installation,
  }) async {
    final buildInfo = await _loadBuildInfo();
    final request = DesktopUpdateRequest(
      platform: installation.platform,
      architecture: installation.architecture,
      distribution: _distribution,
      channel: _channel,
      version: buildInfo.version,
      build: buildInfo.build,
      databaseSchema: desktopDatabaseSchemaVersion,
      protocol: desktopUpdateProtocolVersion,
    );
    final localState = await _repository.readUpdateState(installation.id);

    try {
      final endpointUri = Uri.parse(
        _endpoint,
      ).replace(queryParameters: request.queryParameters);
      final response = await _httpGet(
        endpointUri,
        etag: localState?.cachedEtag,
      );
      // Hoisted so the guard promotes it for the case body; a null-aware read
      // being non-null does not promote the receiver.
      final cachedSignedEnvelope = localState?.cachedSignedEnvelope;
      final signedEnvelope = switch (response.statusCode) {
        200 => response.body,
        304 when cachedSignedEnvelope != null => cachedSignedEnvelope,
        400 => throw const DesktopUpdateException(
          'Deploy Dash sent an invalid update request.',
        ),
        429 => throw const DesktopUpdateException(
          'Update checks are temporarily rate limited.',
        ),
        >= 500 => throw const DesktopUpdateException(
          'The update service is temporarily unavailable.',
        ),
        _ => throw DesktopUpdateException(
          'The update service returned HTTP ${response.statusCode}.',
        ),
      };
      final verified = await _verifyEnvelope(
        signedEnvelope: signedEnvelope,
        request: request,
        deviceId: installation.id,
        buildInfo: buildInfo,
      );
      await _repository.recordUpdateCheck(
        deviceId: installation.id,
        status: verified.status.name,
        releaseId: verified.release?.releaseId,
        signedEnvelope: signedEnvelope,
        etag: response.etag ?? localState?.cachedEtag,
        checkedAt: verified.checkedAt,
      );
      return DesktopUpdateSnapshot(
        status: verified.status,
        currentBuild: buildInfo,
        release: verified.release,
        checkedAt: verified.checkedAt,
        message: verified.message,
        dismissedReleaseId: localState?.dismissedReleaseId,
      );
    } catch (error) {
      final checkedAt = _clock().toUtc();
      await _repository.recordUpdateCheck(
        deviceId: installation.id,
        status: DesktopUpdateStatus.failed.name,
        releaseId: localState?.lastKnownReleaseId,
        signedEnvelope: localState?.cachedSignedEnvelope,
        etag: localState?.cachedEtag,
        checkedAt: checkedAt,
      );
      return DesktopUpdateSnapshot(
        status: DesktopUpdateStatus.failed,
        currentBuild: buildInfo,
        checkedAt: checkedAt,
        message: error is DesktopUpdateException
            ? error.message
            : 'Deploy Dash could not check for updates.',
        dismissedReleaseId: localState?.dismissedReleaseId,
      );
    }
  }

  /// Remembers that the user dismissed [release], so it stops badging.
  Future<void> dismiss({
    required String deviceId,
    required DesktopUpdateRelease release,
  }) {
    return _repository.dismissRelease(
      deviceId: deviceId,
      releaseId: release.releaseId,
      updatedAt: _clock().toUtc(),
    );
  }

  /// Hands [release] to the platform's updater.
  ///
  /// Returns whether the handoff succeeded, not whether the update installed:
  /// once apt, snapd, Sparkle or a store has it, the outcome is theirs to
  /// report.
  Future<bool> startUpdate(DesktopUpdateRelease release) {
    final installer = _installUpdate;
    if (installer != null) {
      return installer(release);
    }
    return _defaultInstallUpdate(release, _launchUri);
  }

  /// Opens the release notes in the user's browser.
  Future<bool> openReleaseNotes(DesktopUpdateRelease release) {
    return _launchUri(release.releaseNotesUri);
  }

  Future<DesktopUpdateSnapshot> _verifyEnvelope({
    required String signedEnvelope,
    required DesktopUpdateRequest request,
    required String deviceId,
    required DesktopBuildInfo buildInfo,
  }) async {
    final envelope = _decodeJsonObject(signedEnvelope, 'signed envelope');
    if (_requiredInt(envelope, 'envelope_version') != 1 ||
        _requiredString(envelope, 'algorithm') != 'Ed25519') {
      throw const DesktopUpdateException(
        'The update response uses an unsupported signature format.',
      );
    }
    final keyId = _requiredString(envelope, 'key_id');
    final encodedPublicKey = _trustedPublicKeys[keyId];
    if (encodedPublicKey == null) {
      throw const DesktopUpdateException(
        'The update response was signed by an unknown key.',
      );
    }
    final payloadBytes = _decodeBase64Url(_requiredString(envelope, 'payload'));
    final signatureBytes = _decodeBase64Url(
      _requiredString(envelope, 'signature'),
    );
    final verified = await Ed25519().verify(
      payloadBytes,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(
          base64Decode(encodedPublicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!verified) {
      throw const DesktopUpdateException(
        'The update response signature is invalid.',
      );
    }

    final payload = _decodeJsonObject(
      utf8.decode(payloadBytes),
      'signed payload',
    );
    if (_requiredInt(payload, 'manifest_version') != 1) {
      throw const DesktopUpdateException(
        'The update response uses an unsupported manifest version.',
      );
    }
    final generatedAt = _requiredDateTime(payload, 'generated_at');
    final expiresAt = _requiredDateTime(payload, 'expires_at');
    final now = _clock().toUtc();
    if (generatedAt.isAfter(now.add(const Duration(minutes: 5))) ||
        !expiresAt.isAfter(now)) {
      throw const DesktopUpdateException(
        'The signed update response has expired.',
      );
    }
    _validateEchoedRequest(payload, request);

    final rawStatus = _requiredString(payload, 'status');
    final status = switch (rawStatus) {
      'current' => DesktopUpdateStatus.current,
      'update_available' => DesktopUpdateStatus.updateAvailable,
      'update_required' => DesktopUpdateStatus.updateRequired,
      'unsupported' => DesktopUpdateStatus.unsupported,
      _ => throw const DesktopUpdateException(
        'The update response contains an unknown status.',
      ),
    };
    final releaseJson = payload['release'];
    final release = releaseJson == null
        ? null
        : _parseRelease(_asObject(releaseJson, 'release'));
    if ((status == DesktopUpdateStatus.updateAvailable ||
            status == DesktopUpdateStatus.updateRequired) &&
        release == null) {
      throw const DesktopUpdateException(
        'The update response is missing release details.',
      );
    }
    if (release != null &&
        !_installStrategyMatchesDistribution(
          release.installStrategy,
          request.distribution,
        )) {
      throw const DesktopUpdateException(
        'The update response does not match this installation source.',
      );
    }
    if (release != null &&
        (desktopDatabaseSchemaVersion < release.minimumDatabaseSchema ||
            desktopDatabaseSchemaVersion > release.maximumDatabaseSchema)) {
      throw const DesktopUpdateException(
        'This update is not compatible with the local database schema.',
      );
    }
    if (release != null &&
        status == DesktopUpdateStatus.updateAvailable &&
        !await _isInRollout(deviceId, release)) {
      return DesktopUpdateSnapshot(
        status: DesktopUpdateStatus.deferred,
        currentBuild: buildInfo,
        release: release,
        checkedAt: now,
        message: 'This release is being rolled out gradually.',
      );
    }
    return DesktopUpdateSnapshot(
      status: status,
      currentBuild: buildInfo,
      release: release,
      checkedAt: now,
      message: _optionalString(payload, 'message'),
    );
  }

  void _validateEchoedRequest(
    Map<String, dynamic> payload,
    DesktopUpdateRequest request,
  ) {
    final echoed = _asObject(payload['request'], 'request');
    for (final entry in request.queryParameters.entries) {
      if (echoed[entry.key]?.toString() != entry.value) {
        throw const DesktopUpdateException(
          'The signed update response does not match this installation.',
        );
      }
    }
  }

  DesktopUpdateRelease _parseRelease(Map<String, dynamic> json) {
    final severity = switch (_requiredString(json, 'severity')) {
      'normal' => DesktopUpdateSeverity.normal,
      'recommended' => DesktopUpdateSeverity.recommended,
      'security' => DesktopUpdateSeverity.security,
      'critical' => DesktopUpdateSeverity.critical,
      _ => throw const DesktopUpdateException(
        'The update response contains an unknown severity.',
      ),
    };
    final compatibility = _asObject(
      json['database_compatibility'],
      'database_compatibility',
    );
    final rollout = _asObject(json['rollout'], 'rollout');
    final install = _asObject(json['install'], 'install');
    final strategy = switch (_requiredString(install, 'strategy')) {
      'apt_repository' => DesktopUpdateInstallStrategy.aptRepository,
      'snap' => DesktopUpdateInstallStrategy.snap,
      'flatpak' => DesktopUpdateInstallStrategy.flatpak,
      'sparkle' => DesktopUpdateInstallStrategy.sparkle,
      'mac_app_store' => DesktopUpdateInstallStrategy.macAppStore,
      'windows_store' => DesktopUpdateInstallStrategy.windowsStore,
      _ => throw const DesktopUpdateException(
        'The update response contains an unknown install strategy.',
      ),
    };
    final rolloutPercentage = _requiredInt(rollout, 'percentage');
    if (rolloutPercentage < 0 || rolloutPercentage > 100) {
      throw const DesktopUpdateException(
        'The update response contains an invalid rollout percentage.',
      );
    }
    final minimumDatabaseSchema = _requiredInt(compatibility, 'minimum_schema');
    final maximumDatabaseSchema = _requiredInt(compatibility, 'maximum_schema');
    if (minimumDatabaseSchema < 0 ||
        maximumDatabaseSchema < minimumDatabaseSchema) {
      throw const DesktopUpdateException(
        'The update response contains an invalid database compatibility range.',
      );
    }
    final releaseNotesUri = _requiredHttpsUri(json, 'release_notes_url');
    final installUri = _requiredInstallUri(install, strategy);
    final artifactSha256 = _optionalString(install, 'sha256');
    if (artifactSha256 != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(artifactSha256)) {
      throw const DesktopUpdateException(
        'The update response contains an invalid artifact checksum.',
      );
    }
    final artifactSize = install['size'] == null
        ? null
        : _requiredInt(install, 'size');
    if (artifactSize != null && artifactSize <= 0) {
      throw const DesktopUpdateException(
        'The update response contains an invalid artifact size.',
      );
    }
    return DesktopUpdateRelease(
      releaseId: _requiredString(json, 'release_id'),
      version: _requiredString(json, 'version'),
      build: _requiredString(json, 'build'),
      publishedAt: _requiredDateTime(json, 'published_at'),
      severity: severity,
      title: _requiredString(json, 'title'),
      summary: _requiredString(json, 'summary'),
      releaseNotesUri: releaseNotesUri,
      minimumSupportedVersion: _requiredString(
        json,
        'minimum_supported_version',
      ),
      minimumSupportedBuild: _requiredString(json, 'minimum_supported_build'),
      minimumDatabaseSchema: minimumDatabaseSchema,
      maximumDatabaseSchema: maximumDatabaseSchema,
      rolloutPercentage: rolloutPercentage,
      rolloutSalt: _requiredString(rollout, 'salt'),
      installStrategy: strategy,
      installUri: installUri,
      artifactSha256: artifactSha256,
      artifactSize: artifactSize,
    );
  }

  Future<bool> _isInRollout(
    String deviceId,
    DesktopUpdateRelease release,
  ) async {
    if (release.rolloutPercentage >= 100) {
      return true;
    }
    if (release.rolloutPercentage <= 0) {
      return false;
    }
    final hash = await Sha256().hash(
      utf8.encode('${release.rolloutSalt}:$deviceId'),
    );
    final project = ((hash.bytes[0] << 8) | hash.bytes[1]) % 100;
    return project < release.rolloutPercentage;
  }
}

bool _installStrategyMatchesDistribution(
  DesktopUpdateInstallStrategy strategy,
  String distribution,
) {
  return switch (distribution) {
    'deb' => strategy == DesktopUpdateInstallStrategy.aptRepository,
    'snap' => strategy == DesktopUpdateInstallStrategy.snap,
    'flatpak' => strategy == DesktopUpdateInstallStrategy.flatpak,
    'dmg' => strategy == DesktopUpdateInstallStrategy.sparkle,
    'mac_app_store' => strategy == DesktopUpdateInstallStrategy.macAppStore,
    'windows_store' => strategy == DesktopUpdateInstallStrategy.windowsStore,
    _ => false,
  };
}

// Strict update-envelope validation — DesktopUpdateException taxonomy, not a
// null-decoder (D-45 pair 2, T-021).
Map<String, dynamic> _decodeJsonObject(String value, String label) {
  try {
    return _asObject(jsonDecode(value), label);
  } on FormatException {
    throw DesktopUpdateException('The $label is not valid JSON.');
  }
}

Map<String, dynamic> _asObject(Object? value, String label) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  throw DesktopUpdateException('The $label must be a JSON object.');
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw DesktopUpdateException('The update response is missing $key.');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  final parsed = int.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    throw DesktopUpdateException('The update response has an invalid $key.');
  }
  return parsed;
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final parsed = DateTime.tryParse(json[key]?.toString() ?? '');
  if (parsed == null) {
    throw DesktopUpdateException('The update response has an invalid $key.');
  }
  return parsed.toUtc();
}

Uri _requiredUri(Map<String, dynamic> json, String key) {
  final parsed = Uri.tryParse(_requiredString(json, key));
  if (parsed == null || !parsed.hasScheme) {
    throw DesktopUpdateException('The update response has an invalid $key.');
  }
  return parsed;
}

Uri _requiredHttpsUri(Map<String, dynamic> json, String key) {
  final parsed = _requiredUri(json, key);
  if (parsed.scheme != 'https' || parsed.host.isEmpty) {
    throw DesktopUpdateException('The update response requires an HTTPS $key.');
  }
  return parsed;
}

Uri _requiredInstallUri(
  Map<String, dynamic> json,
  DesktopUpdateInstallStrategy strategy,
) {
  final parsed = _requiredUri(json, 'uri');
  final valid = switch (strategy) {
    DesktopUpdateInstallStrategy.aptRepository => parsed.scheme == 'apt',
    DesktopUpdateInstallStrategy.snap => parsed.scheme == 'snap',
    DesktopUpdateInstallStrategy.flatpak => parsed.scheme == 'appstream',
    DesktopUpdateInstallStrategy.sparkle =>
      parsed.scheme == 'https' && parsed.host.isNotEmpty,
    DesktopUpdateInstallStrategy.macAppStore => parsed.scheme == 'macappstore',
    DesktopUpdateInstallStrategy.windowsStore =>
      parsed.toString() == desktopWindowsStoreInstallUri,
  };
  if (!valid) {
    throw const DesktopUpdateException(
      'The update response contains an invalid install URI.',
    );
  }
  return parsed;
}

List<int> _decodeBase64Url(String value) {
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    throw const DesktopUpdateException(
      'The update response contains invalid signed data.',
    );
  }
}

Future<DesktopUpdateHttpResponse> _defaultHttpGet(
  Uri uri, {
  String? etag,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (etag != null && etag.trim().isNotEmpty) {
      request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    }
    final response = await request.close();
    return DesktopUpdateHttpResponse(
      statusCode: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
      etag: response.headers.value(HttpHeaders.etagHeader),
    );
  } finally {
    client.close(force: true);
  }
}

Future<DesktopBuildInfo> _defaultLoadBuildInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return DesktopBuildInfo(version: info.version, build: info.buildNumber);
  } on PlatformException {
    return const DesktopBuildInfo(
      version: desktopReleaseVersion,
      build: desktopReleaseBuild,
    );
  } on MissingPluginException {
    return const DesktopBuildInfo(
      version: desktopReleaseVersion,
      build: desktopReleaseBuild,
    );
  }
}

Future<bool> _defaultLaunchUri(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<bool> _defaultInstallUpdate(
  DesktopUpdateRelease release,
  DesktopUpdateUriLauncher launchUri,
) async {
  if (release.installStrategy != DesktopUpdateInstallStrategy.sparkle) {
    return launchUri(release.installUri);
  }
  try {
    return await _desktopUpdateChannel.invokeMethod<bool>(
          'checkForUpdates',
          <String, String>{'feedUrl': release.installUri.toString()},
        ) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// The app-wide update service.
final desktopUpdateServiceProvider = Provider<DesktopUpdateService>((ref) {
  return DesktopUpdateService(
    repository: ref.watch(deviceInstallationRepositoryProvider),
  );
});

/// Holds the current update snapshot for the UI.
///
/// Starts at [DesktopUpdateSnapshot.notChecked] rather than checking on build:
/// the check is a network call, and app startup should not wait on the update
/// service being reachable.
class DesktopUpdateController extends AsyncNotifier<DesktopUpdateSnapshot> {
  DesktopUpdateSnapshot? get _currentSnapshot {
    return switch (state) {
      AsyncData<DesktopUpdateSnapshot>(:final value) => value,
      _ => null,
    };
  }

  @override
  Future<DesktopUpdateSnapshot> build() async {
    final build = await ref.watch(desktopUpdateServiceProvider).loadBuildInfo();
    return DesktopUpdateSnapshot.notChecked(build);
  }

  /// Runs a check and publishes the result.
  ///
  /// Guarded, so even an unexpected failure lands as an error state rather
  /// than an unhandled exception.
  Future<void> check() async {
    state = const AsyncLoading<DesktopUpdateSnapshot>();
    state = await AsyncValue.guard(() async {
      final installation = await ref.read(
        currentDeviceInstallationProvider.future,
      );
      return ref
          .read(desktopUpdateServiceProvider)
          .check(installation: installation);
    });
    // The service never throws (failures land in the snapshot), so a snapshot
    // here means a check resolved. An error state means the installation
    // lookup itself failed and no check ran, which reports nothing.
    final snapshot = _currentSnapshot;
    if (snapshot == null) {
      return;
    }
    ref
        .read(appAnalyticsServiceProvider)
        .trackUpdateEvent(
          action: UpdateAction.check,
          outcome: snapshot.status == DesktopUpdateStatus.failed
              ? DataOperationOutcome.failure
              : DataOperationOutcome.success,
          fromVersion: snapshot.currentBuild.version,
        );
  }

  /// Starts installing the release in the current snapshot.
  ///
  /// False when there is nothing to install.
  Future<bool> startUpdate() async {
    final snapshot = _currentSnapshot;
    final release = snapshot?.release;
    if (release == null) {
      return false;
    }
    final started = await ref
        .read(desktopUpdateServiceProvider)
        .startUpdate(release);
    ref
        .read(appAnalyticsServiceProvider)
        .trackUpdateEvent(
          action: UpdateAction.apply,
          outcome: started
              ? DataOperationOutcome.success
              : DataOperationOutcome.failure,
          fromVersion: snapshot!.currentBuild.version,
        );
    return started;
  }

  /// Opens the current release's notes. False when there is no release.
  Future<bool> openReleaseNotes() async {
    final release = _currentSnapshot?.release;
    if (release == null) {
      return false;
    }
    return ref.read(desktopUpdateServiceProvider).openReleaseNotes(release);
  }

  /// Dismisses the current release and updates the snapshot in place.
  ///
  /// [DesktopUpdateSnapshot.status] is deliberately left alone: the release is
  /// still available, the user has just asked to stop being told.
  Future<void> dismiss() async {
    final snapshot = _currentSnapshot;
    final release = snapshot?.release;
    if (snapshot == null || release == null) {
      return;
    }
    final installation = await ref.read(
      currentDeviceInstallationProvider.future,
    );
    await ref
        .read(desktopUpdateServiceProvider)
        .dismiss(deviceId: installation.id, release: release);
    state = AsyncData(
      DesktopUpdateSnapshot(
        status: snapshot.status,
        currentBuild: snapshot.currentBuild,
        release: release,
        checkedAt: snapshot.checkedAt,
        message: snapshot.message,
        dismissedReleaseId: release.releaseId,
      ),
    );
  }
}

/// The update snapshot the shell's badge and settings screen read.
final desktopUpdateControllerProvider =
    AsyncNotifierProvider<DesktopUpdateController, DesktopUpdateSnapshot>(
      DesktopUpdateController.new,
    );
