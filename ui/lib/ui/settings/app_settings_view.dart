import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers/app_settings_provider.dart';
import '../../providers/agent_access_service.dart';
import '../../providers/project_provider.dart';
import '../../providers/server_list_provider.dart';
import '../../providers/server_provider.dart';
import '../../providers/telemetry_settings_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/sqlite_backup_service.dart';
import '../../services/ssh_service.dart';
import '../system/app_copy.dart';
import '../system/app_context_navigation.dart';
import '../system/app_dialogs.dart';
import '../system/app_forms.dart';
import '../system/app_sections.dart';
import '../../models/storage_failure_mapper.dart';
import '../system/app_workspace.dart';
import '../navigation/desktop_route.dart';
import 'desktop_updates_view.dart';

typedef LocalBackupExportPathPicker =
    Future<String?> Function(String suggestedName);
typedef LocalBackupRestorePathPicker = Future<String?> Function();
typedef AppDatabasePassphraseRotator =
    Future<void> Function({
      required AppDatabase database,
      required String currentPassphrase,
      required String newPassphrase,
    });
typedef AppDatabaseBackupPassphraseValidator =
    Future<bool> Function({
      required String sourcePath,
      required String passphrase,
    });
typedef AppDatabaseRestoreHandler =
    Future<File> Function({required String sourcePath, bool overwriteExisting});
typedef AppDatabaseBackupFormatEnforcer =
    Future<void> Function({
      required String sourcePath,
      required String passphrase,
    });
typedef AgentAccessStatusLoader = Future<AgentAccessStatusSnapshot> Function();
typedef AgentAccessEnabledSetter = Future<void> Function(bool enabled);
typedef AgentAccessPermissionSetter = Future<void> Function(String mode);
typedef AgentAccessSessionIssuer = Future<String> Function();
typedef AgentAccessSessionRevoker = Future<void> Function();

LocalBackupExportPathPicker? _debugExportPathPicker;
LocalBackupRestorePathPicker? _debugRestorePathPicker;

void debugOverrideAppSettingsLocalBackupPickers({
  LocalBackupExportPathPicker? exportPathPicker,
  LocalBackupRestorePathPicker? restorePathPicker,
}) {
  _debugExportPathPicker = exportPathPicker;
  _debugRestorePathPicker = restorePathPicker;
}

class AppSettingsView extends ConsumerStatefulWidget {
  const AppSettingsView({
    super.key,
    this.pickExportPath = _pickLocalBackupExportPath,
    this.pickRestorePath = _pickLocalBackupRestorePath,
    this.rotateDatabasePassphrase = rotateAppDatabasePassphrase,
    this.validateRestorePassphrase = validateAppDatabaseBackupPassphrase,
    this.enforceBackupFormatVersion = enforceSqliteBackupFormatVersion,
    this.restoreBackupFile = restoreAppDatabaseFromBackupFile,
    this.loadAgentAccessStatus,
    this.setAgentAccessEnabled,
    this.setAgentAccessPermissionMode,
    this.issueAgentAccessSession,
    this.revokeAgentAccessSession,
    this.initialDestinationId,
    this.onDestinationSelected,
  });

  final LocalBackupExportPathPicker pickExportPath;
  final LocalBackupRestorePathPicker pickRestorePath;
  final AppDatabasePassphraseRotator rotateDatabasePassphrase;
  final AppDatabaseBackupPassphraseValidator validateRestorePassphrase;
  final AppDatabaseBackupFormatEnforcer enforceBackupFormatVersion;
  final AppDatabaseRestoreHandler restoreBackupFile;
  final AgentAccessStatusLoader? loadAgentAccessStatus;
  final AgentAccessEnabledSetter? setAgentAccessEnabled;
  final AgentAccessPermissionSetter? setAgentAccessPermissionMode;
  final AgentAccessSessionIssuer? issueAgentAccessSession;
  final AgentAccessSessionRevoker? revokeAgentAccessSession;
  final String? initialDestinationId;
  final ValueChanged<String>? onDestinationSelected;

  @override
  ConsumerState<AppSettingsView> createState() => _AppSettingsViewState();
}

class _AppSettingsViewState extends ConsumerState<AppSettingsView> {
  static final _destinations = <AppContextNavigationItem>[
    AppContextNavigationItem(
      id: DesktopAppSettingsDestination.appearance.id,
      label: 'Appearance',
      icon: Icons.palette_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopAppSettingsDestination.updates.id,
      label: 'Updates',
      icon: Icons.system_update_alt_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopAppSettingsDestination.agentAccess.id,
      label: 'Agent Access',
      icon: Icons.smart_toy_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopAppSettingsDestination.appBackup.id,
      label: 'App backup',
      icon: Icons.backup_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopAppSettingsDestination.security.id,
      label: 'Security',
      icon: Icons.lock_outline,
    ),
    AppContextNavigationItem(
      id: DesktopAppSettingsDestination.privacy.id,
      label: 'Privacy',
      icon: Icons.privacy_tip_outlined,
    ),
  ];
  static final _destinationSubtitles = <String>[
    'Choose how Deploy Dash looks on this computer.',
    'Check this installation and open its trusted update service.',
    'Control local integrations and time-limited redeploy access.',
    'Protect, export, and restore the encrypted local app database.',
    'Change the password used to unlock Deploy Dash on this computer.',
    privacySectionSubtitle(),
  ];
  final TextEditingController _bucketController = TextEditingController();
  final TextEditingController _regionController = TextEditingController();
  final TextEditingController _prefixController = TextEditingController();
  final TextEditingController _accessKeyController = TextEditingController();
  final TextEditingController _secretKeyController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _retentionController = TextEditingController(
    text: '7',
  );
  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmNewPasswordController =
      TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _runningBackup = false;
  bool _exporting = false;
  bool _restoringFromS3 = false;
  bool _restoringLocal = false;
  bool _changingPassword = false;
  bool _updatingAgentAccess = false;
  bool _issuingAgentSession = false;
  bool _revokingAgentSession = false;
  bool _forcePathStyle = false;
  bool _telemetryEnabled = true;
  bool _updatingTelemetry = false;
  String? _telemetryError;
  bool _agentAccessEnabled = false;
  String _agentPermissionMode = agentAccessPermissionReadOnly;
  String? _backupError;

  /// Failures from the S3 destination card, kept separate from
  /// [_backupError] so each renders beside the control that produced it.
  /// Sharing one slot is why this message used to appear in a different card,
  /// a hundred lines below the button. G-39.
  StorageFailureMessage? _s3DestinationError;
  String? _passwordError;
  String? _agentAccessError;
  String? _backupStatus;
  String? _backupMessage;
  String? _verifiedS3ConfigFingerprint;
  String? _agentSessionToken;
  String? _agentServerError;
  DateTime? _backupLastRunAt;
  DateTime? _agentSessionExpiresAt;
  List<AgentAuditEntryRecord> _recentAgentActions = const [];
  List<EngineTaskHistoryEntry> _runningAgentTasks = const [];
  List<EngineTaskHistoryEntry> _recentAgentTaskResults = const [];
  int _selectedDestinationIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectRequestedDestination(widget.initialDestinationId);
    unawaited(_loadPreferences());
  }

  @override
  void didUpdateWidget(covariant AppSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialDestinationId != oldWidget.initialDestinationId) {
      _selectRequestedDestination(widget.initialDestinationId);
    }
  }

  void _selectRequestedDestination(String? destinationId) {
    final requestedDestination = destinationId?.trim();
    final requestedIndex = _destinations.indexWhere(
      (destination) => destination.id == requestedDestination,
    );
    if (requestedIndex >= 0) {
      _selectedDestinationIndex = requestedIndex;
    }
  }

  @override
  void dispose() {
    _bucketController.dispose();
    _regionController.dispose();
    _prefixController.dispose();
    _accessKeyController.dispose();
    _secretKeyController.dispose();
    _endpointController.dispose();
    _retentionController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmNewPasswordController.dispose();
    super.dispose();
  }

  Future<AgentAccessStatusSnapshot> _readAgentAccessStatus() {
    final loader = widget.loadAgentAccessStatus;
    if (loader != null) {
      return loader();
    }
    return ref
        .read(agentAccessServiceProvider)
        .readStatus(); // coverage:ignore-line
  }

  Future<void> _setAgentAccessEnabled(bool enabled) {
    final setter = widget.setAgentAccessEnabled;
    if (setter != null) {
      return setter(enabled);
    }
    return ref
        .read(agentAccessServiceProvider)
        .setEnabled(enabled); // coverage:ignore-line
  }

  Future<void> _setAgentAccessPermissionMode(String mode) {
    final setter = widget.setAgentAccessPermissionMode;
    if (setter != null) {
      return setter(mode);
    }
    return ref
        .read(agentAccessServiceProvider)
        .setPermissionMode(mode); // coverage:ignore-line
  }

  Future<String> _issueAgentAccessSession() {
    final issuer = widget.issueAgentAccessSession;
    if (issuer != null) {
      return issuer();
    }
    return ref
        .read(agentAccessServiceProvider)
        .issueSession(); // coverage:ignore-line
  }

  Future<void> _revokeAgentAccessSession() {
    final revoker = widget.revokeAgentAccessSession;
    if (revoker != null) {
      return revoker();
    }
    return ref
        .read(agentAccessServiceProvider)
        .revokeSession(); // coverage:ignore-line
  }

  Future<void> _loadPreferences() async {
    setState(() {
      _loading = true;
      _backupError = null;
      _agentAccessError = null;
    });
    try {
      final preferences = await ref
          .read(appPreferencesRepositoryProvider)
          .read();
      final configJson = preferences.sqliteBackupS3Config;
      final config = configJson == null
          ? null
          : SqliteBackupS3Config.fromJson(configJson);
      final agentStatus = await _readAgentAccessStatus();

      if (!mounted) {
        return;
      }
      setState(() {
        _telemetryEnabled = preferences.telemetryEnabled ?? true;
        _updatingTelemetry = false;
        _telemetryError = null;
        _bucketController.text = config?.bucket ?? '';
        _regionController.text = config?.region ?? '';
        _prefixController.text = config?.prefix ?? '';
        _accessKeyController.text = config?.accessKeyId ?? '';
        _secretKeyController.text = config?.secretAccessKey ?? '';
        _endpointController.text = config?.endpoint ?? '';
        _forcePathStyle = config?.forcePathStyle ?? false;
        _retentionController.text = (config?.retentionKeepLast ?? 7).toString();
        _backupLastRunAt = preferences.sqliteBackupLastRunAt;
        _backupStatus = preferences.sqliteBackupLastStatus;
        _backupMessage = preferences.sqliteBackupLastMessage;
        _agentAccessEnabled = agentStatus.enabled;
        _agentPermissionMode = agentStatus.permissionMode;
        _agentSessionToken = agentStatus.sessionToken;
        _agentSessionExpiresAt = agentStatus.sessionExpiresAt;
        _agentServerError = agentStatus.serverError;
        _recentAgentActions = agentStatus.recentActions;
        _runningAgentTasks = agentStatus.runningTasks;
        _recentAgentTaskResults = agentStatus.recentTaskResults;
        _updatingAgentAccess = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _backupError = couldntMessage('load app settings', error);
      });
    }
  }

  SqliteBackupS3Config _buildConfigFromInputs() {
    return SqliteBackupS3Config(
      bucket: _bucketController.text.trim(),
      region: _regionController.text.trim(),
      prefix: _prefixController.text.trim(),
      accessKeyId: _accessKeyController.text.trim(),
      secretAccessKey: _secretKeyController.text.trim(),
      endpoint: _endpointController.text.trim().isEmpty
          ? null
          : _endpointController.text.trim(),
      forcePathStyle: _forcePathStyle,
      // Omitting this is not harmless: `toJson` always writes the field, so a
      // config built without it overwrites a stored value with the default
      // every time the destination is saved. G-44.
      retentionKeepLast:
          int.tryParse(_retentionController.text.trim()) ?? _invalidRetention,
    );
  }

  /// Out-of-range on purpose, so `validate()` rejects unparseable input
  /// instead of silently substituting the default.
  static const int _invalidRetention = -1;

  String _s3ConfigFingerprint(SqliteBackupS3Config config) =>
      jsonEncode(config.toJson());

  bool get _isS3DestinationVerified =>
      _verifiedS3ConfigFingerprint ==
      _s3ConfigFingerprint(_buildConfigFromInputs());

  String? get _s3ConfigBlockingReason {
    try {
      _buildConfigFromInputs().validate();
    } on FormatException catch (error) {
      return error.message;
    }
    if (!_isS3DestinationVerified) {
      return 'Test and save this destination before using S3 backup actions.';
    }
    return null;
  }

  void _onS3ConfigChanged([Object? _]) {
    setState(() {});
  }

  Future<void> _saveBackupConfig() async {
    final config = _buildConfigFromInputs();
    try {
      config.validate();
    } on FormatException {
      // Nothing to render: `_s3ConfigBlockingReason` already states which
      // field is missing, directly beside this button. Adding a second
      // message would put the same sentence on screen twice, and the old
      // `_backupError` assignment put it in a different card entirely. G-39.
      return;
    }

    setState(() {
      _saving = true;
      _backupError = null;
      _s3DestinationError = null;
    });
    try {
      await ref
          .read(sqliteBackupServiceProvider)
          .verifyS3Destination(config: config);
      await ref
          .read(appPreferencesRepositoryProvider)
          .setSqliteBackupS3Config(config.toJson());
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _verifiedS3ConfigFingerprint = _s3ConfigFingerprint(config);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('S3 destination tested and saved.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        // G-38: the provider's XML body used to be interpolated straight into
        // the message. The sentence goes on the primary path; the raw body
        // survives behind the technical-details reveal.
        _s3DestinationError = mapStorageFailure(error);
      });
    }
  }

  Future<void> _runBackupNow() async {
    final config = _buildConfigFromInputs();
    try {
      config.validate();
    } catch (error) {
      setState(() {
        _backupError = error.toString();
      });
      return;
    }

    setState(() {
      _runningBackup = true;
      _backupError = null;
    });
    try {
      await ref
          .read(appPreferencesRepositoryProvider)
          .setSqliteBackupS3Config(config.toJson());
      final result = await ref
          .read(sqliteBackupServiceProvider)
          .backupNow(config: config);

      if (!mounted) {
        return;
      }
      setState(() {
        _runningBackup = false;
        _backupLastRunAt = result.completedAt;
        _backupStatus = 'success';
        _backupMessage = result.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningBackup = false;
        _backupLastRunAt = DateTime.now();
        _backupStatus = 'failed';
        _backupMessage = error.toString();
        _backupError = couldntMessage('back up the local app database', error);
      });
    }
  }

  Future<void> _exportEncryptedDatabase() async {
    final suggestedName = buildSqliteBackupFilename(DateTime.now().toUtc());
    final destinationPath =
        await (_debugExportPathPicker ?? widget.pickExportPath)(suggestedName);
    if (!mounted || destinationPath == null) {
      return;
    }

    setState(() {
      _exporting = true;
      _backupError = null;
    });
    try {
      final exportedFile = await ref
          .read(sqliteBackupServiceProvider)
          .exportNow(destinationPath: destinationPath);

      if (!mounted) {
        return;
      }
      setState(() {
        _exporting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Encrypted database exported to ${exportedFile.path}.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _exporting = false;
        _backupError = couldntMessage(
          'save the encrypted database copy',
          error,
        );
      });
    }
  }

  Future<bool> _confirmBackupRestore({
    required String title,
    required String description,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDestructiveConfirmDialog(
        title: title,
        description: description,
        confirmLabel: confirmLabel,
      ),
    );
    return confirmed == true;
  }

  Future<void> _showBackupRestoreError(String message) async {
    await showAppNotice(
      context,
      title: 'Couldn\'t restore app backup',
      message: message,
    );
  }

  Future<void> _refreshStateAfterDatabaseRestore() async {
    ref.invalidate(appDatabaseProvider);
    ref.invalidate(appPreferencesRepositoryProvider);
    ref.invalidate(sqliteBackupServiceProvider);
    ref.invalidate(serverCatalogProvider);
    ref.invalidate(serverProvider);
    ref.invalidate(projectListProvider);
    ref.invalidate(selectedProjectIdProvider);
    ref.invalidate(themeProvider);
    ref.invalidate(agentAccessServiceProvider);
    await _loadPreferences();
  }

  Future<void> _restoreBackupFromPath({
    required String sourcePath,
    String? successMessage,
  }) async {
    final currentPassphrase =
        ref.read(databasePassphraseProvider)?.trim() ?? '';
    if (currentPassphrase.isEmpty) {
      throw StateError(
        'Your current app password is unavailable for backup restore.',
      );
    }

    final matchesCurrentPassword = await widget.validateRestorePassphrase(
      sourcePath: sourcePath,
      passphrase: currentPassphrase,
    );
    if (!matchesCurrentPassword) {
      throw StateError(appSettingsBackupPasswordMismatchMessage());
    }

    // Checked before anything destructive happens below: this is the one
    // restore path that already knows the passphrase up front, so the
    // refusal can land before the live database is ever closed or replaced,
    // not just before it is reopened.
    await widget.enforceBackupFormatVersion(
      sourcePath: sourcePath,
      passphrase: currentPassphrase,
    );

    final database = ref.read(appDatabaseProvider);
    await database.close();
    try {
      await widget.restoreBackupFile(
        sourcePath: sourcePath,
        overwriteExisting: true,
      );
    } finally {
      await _refreshStateAfterDatabaseRestore();
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(successMessage ?? 'App backup restored.')),
    );
  }

  Future<void> _restoreLatestBackupFromS3() async {
    final confirmed = await _confirmBackupRestore(
      title: 'Restore the latest S3 backup?',
      description:
          'Deploy Dash will download the newest encrypted app backup from '
          'this S3 destination and permanently replace the current local app '
          'database, including saved servers, projects, and settings. '
          'Use a backup created with your current app password.',
      confirmLabel: 'Replace app data from S3',
    );
    if (!confirmed || !mounted) {
      return;
    }

    final config = _buildConfigFromInputs();
    try {
      config.validate();
    } catch (error) {
      setState(() {
        _backupError = error.toString();
      });
      return;
    }

    setState(() {
      _restoringFromS3 = true;
      _backupError = null;
    });

    SqliteBackupDownloadResult? download;
    try {
      await ref
          .read(appPreferencesRepositoryProvider)
          .setSqliteBackupS3Config(config.toJson());
      download = await ref
          .read(sqliteBackupServiceProvider)
          .downloadLatestBackupFromS3(config: config);
      await _restoreBackupFromPath(
        sourcePath: download.localFile.path,
        successMessage:
            'App backup restored from s3://${config.bucket}/${download.objectKey}.',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _restoringFromS3 = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = couldntMessage('restore the app backup', error);
      setState(() {
        _restoringFromS3 = false;
        _backupError = message;
      });
      await _showBackupRestoreError(message);
    } finally {
      final downloadedFile = download?.localFile;
      if (downloadedFile != null) {
        final scratchDir = downloadedFile.parent;
        if (await scratchDir.exists()) {
          await scratchDir.delete(recursive: true);
        }
      }
    }
  }

  Future<void> _restoreFromLocalCopy() async {
    final sourcePath =
        await (_debugRestorePathPicker ?? widget.pickRestorePath)();
    if (!mounted || sourcePath == null) {
      return;
    }

    final fileName = p.basename(sourcePath);
    final confirmed = await _confirmBackupRestore(
      title: 'Restore this local backup?',
      description:
          'Deploy Dash will permanently replace the current local app database, '
          'including saved servers, projects, and settings, with $fileName. '
          'Use a backup created with your current app password.',
      confirmLabel: 'Replace app data from local backup',
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() {
      _restoringLocal = true;
      _backupError = null;
    });
    try {
      await _restoreBackupFromPath(
        sourcePath: sourcePath,
        successMessage: 'App backup restored from $fileName.',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _restoringLocal = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = couldntMessage('restore the app backup', error);
      setState(() {
        _restoringLocal = false;
        _backupError = message;
      });
      await _showBackupRestoreError(message);
    }
  }

  Future<void> _changePassword() async {
    final currentPassword = _currentPasswordController.text.trim();
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmNewPasswordController.text.trim();

    if (currentPassword.isEmpty) {
      setState(() {
        _passwordError = 'Enter your current password.';
      });
      return;
    }
    if (newPassword.isEmpty) {
      setState(() {
        _passwordError = 'Enter a new password.';
      });
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() {
        _passwordError = 'New passwords do not match.';
      });
      return;
    }

    setState(() {
      _changingPassword = true;
      _passwordError = null;
    });

    try {
      final database = ref.read(appDatabaseProvider);
      await widget.rotateDatabasePassphrase(
        database: database,
        currentPassphrase: currentPassword,
        newPassphrase: newPassword,
      );
      ref.read(databasePassphraseProvider.notifier).setPassphrase(newPassword);

      if (!mounted) {
        return;
      }
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmNewPasswordController.clear();
      setState(() {
        _changingPassword = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Password updated.')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _changingPassword = false;
        _passwordError = couldntMessage('update the app password', error);
      });
    }
  }

  /// Flips usage reporting either way, in storage and on the live service
  /// together. The single funnel behind the setup notice's switch too.
  Future<void> _toggleTelemetry(bool enabled) async {
    setState(() {
      _updatingTelemetry = true;
      _telemetryError = null;
    });
    try {
      await ref.read(telemetrySettingsProvider.notifier).setEnabled(enabled);
      if (!mounted) {
        return;
      }
      setState(() {
        _telemetryEnabled = enabled;
        _updatingTelemetry = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _updatingTelemetry = false;
        _telemetryError = couldntMessage('update usage reporting', error);
      });
    }
  }

  Future<void> _toggleAgentAccess(bool enabled) async {
    setState(() {
      _updatingAgentAccess = true;
      _agentAccessError = null;
    });
    try {
      await _setAgentAccessEnabled(enabled);
      await _loadPreferences();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _updatingAgentAccess = false;
        _agentAccessError = couldntMessage('update local agent access', error);
      });
    }
  }

  Future<void> _changeAgentPermissionMode(String mode) async {
    setState(() {
      _updatingAgentAccess = true;
      _agentAccessError = null;
    });
    try {
      await _setAgentAccessPermissionMode(mode);
      await _loadPreferences();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _updatingAgentAccess = false;
        _agentAccessError = couldntMessage(
          'update local agent access mode',
          error,
        );
      });
    }
  }

  Future<void> _issueSession() async {
    setState(() {
      _issuingAgentSession = true;
      _agentAccessError = null;
    });
    try {
      final token = await _issueAgentAccessSession();
      if (!mounted) {
        return;
      }
      await _loadPreferences();
      if (!mounted) {
        return;
      }
      setState(() {
        _issuingAgentSession = false;
        _agentSessionToken = token;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Agent session issued.')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _issuingAgentSession = false;
        _agentAccessError = couldntMessage('start a redeploy session', error);
      });
    }
  }

  Future<void> _revokeSession() async {
    setState(() {
      _revokingAgentSession = true;
      _agentAccessError = null;
    });
    try {
      await _revokeAgentAccessSession();
      if (!mounted) {
        return;
      }
      await _loadPreferences();
      if (!mounted) {
        return;
      }
      setState(() {
        _revokingAgentSession = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Agent session revoked.')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _revokingAgentSession = false;
        _agentAccessError = couldntMessage('end the redeploy session', error);
      });
    }
  }

  String _formatSessionExpiry(DateTime? value) {
    if (value == null) {
      return 'No active session';
    }
    return value.toLocal().toString();
  }

  bool get _hasActiveAgentSession {
    final token = _agentSessionToken?.trim();
    final expiresAt = _agentSessionExpiresAt;
    if (token == null || token.isEmpty || expiresAt == null) {
      return false;
    }
    return expiresAt.isAfter(DateTime.now());
  }

  String _formatAgentTaskSummary(EngineTaskHistoryEntry entry) {
    return formatAgentActivitySummary(
      workflowId: entry.workflowId,
      operationId: entry.operationId,
      taskId: entry.taskId,
      status: entry.status,
      message: entry.message,
    );
  }

  void _selectDestination(int index) {
    setState(() {
      _selectedDestinationIndex = index;
    });
    widget.onDestinationSelected?.call(_destinations[index].id);
  }

  bool get _backupActionBusy =>
      _saving ||
      _runningBackup ||
      _exporting ||
      _restoringFromS3 ||
      _restoringLocal ||
      _changingPassword;

  List<Widget> _buildAppBackupSections(BuildContext context) {
    final theme = Theme.of(context);
    final s3BlockingReason = _s3ConfigBlockingReason;
    final s3Ready = s3BlockingReason == null;
    final s3DestinationError = _s3DestinationError;
    final backupMessage = _backupMessage;
    final backupError = _backupError;
    return <Widget>[
      AppWorkspaceSection(
        key: const Key('app-settings-app-backup-section'),
        title: 'S3 destination',
        subtitle: 'Test where encrypted app backups will be stored.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppStatusBadge(
              key: const Key('app-settings-s3-status'),
              label: s3Ready ? 'Tested and ready' : 'Setup required',
              tone: s3Ready ? AppStatusTone.positive : AppStatusTone.warning,
              icon: s3Ready
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
            ),
            const SizedBox(height: 12),
            AppTextFormField(
              fieldKey: const Key('app-settings-s3-bucket-field'),
              controller: _bucketController,
              labelText: 'S3 bucket',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 10),
            AppTextFormField(
              fieldKey: const Key('app-settings-s3-region-field'),
              controller: _regionController,
              labelText: 'S3 region',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 10),
            AppTextFormField(
              fieldKey: const Key('app-settings-s3-prefix-field'),
              controller: _prefixController,
              labelText: 'Object prefix',
              hintText: 'deploydash/backups/sqlite',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 10),
            AppTextFormField(
              fieldKey: const Key('app-settings-s3-access-key-field'),
              controller: _accessKeyController,
              labelText: 'Access key ID',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 10),
            AppPasswordFormField(
              fieldKey: const Key('app-settings-s3-secret-key-field'),
              controller: _secretKeyController,
              labelText: 'Secret access key',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 10),
            AppTextFormField(
              fieldKey: const Key('app-settings-s3-endpoint-field'),
              controller: _endpointController,
              labelText: 'S3 endpoint (optional)',
              hintText: 'https://s3.us-east-1.amazonaws.com',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 10),
            AppNumberFormField(
              fieldKey: const Key('app-settings-s3-retention-field'),
              controller: _retentionController,
              labelText: 'Backups to keep',
              helperText:
                  'Older snapshots are removed after a successful backup.',
              onChanged: _onS3ConfigChanged,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('app-settings-s3-force-path-style-toggle'),
              contentPadding: EdgeInsets.zero,
              value: _forcePathStyle,
              title: const Text('Force path-style addressing'),
              onChanged: _backupActionBusy
                  ? null
                  : (value) {
                      setState(() {
                        _forcePathStyle = value;
                      });
                    },
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('app-settings-s3-save-button'),
              onPressed: _backupActionBusy ? null : _saveBackupConfig,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_done_outlined),
              label: const Text('Test and save destination'),
            ),
            if (s3BlockingReason != null) ...[
              const SizedBox(height: 8),
              Text(
                s3BlockingReason,
                key: const Key('app-settings-s3-blocking-reason'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (s3DestinationError != null) ...[
              const SizedBox(height: 8),
              Text(
                s3DestinationError.message,
                key: const Key('app-settings-s3-destination-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              if (s3DestinationError.detail.isNotEmpty) ...[
                const SizedBox(height: 6),
                AppTechnicalDetails(
                  key: const Key('app-settings-s3-destination-error-details'),
                  child: SelectableText(
                    s3DestinationError.detail,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      AppWorkspaceSection(
        key: const Key('app-settings-create-backup-section'),
        title: 'Create backup',
        subtitle: 'Create an encrypted copy of the local Deploy Dash database.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Latest result: ${_backupLastRunAt ?? 'No S3 backup run yet'}',
              style: theme.textTheme.bodySmall,
            ),
            if ((_backupStatus ?? '').trim().isNotEmpty)
              Text('Status: $_backupStatus', style: theme.textTheme.bodySmall),
            if (backupMessage != null && backupMessage.trim().isNotEmpty)
              Text(backupMessage, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('app-settings-backup-run-button'),
                  onPressed: _backupActionBusy || !s3Ready
                      ? null
                      : _runBackupNow,
                  icon: _runningBackup
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.backup),
                  label: const Text('Backup to S3'),
                ),
                OutlinedButton.icon(
                  key: const Key('app-settings-backup-export-button'),
                  onPressed: _backupActionBusy
                      ? null
                      : _exportEncryptedDatabase,
                  icon: _exporting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text('Save local backup'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      AppWorkspaceSection(
        key: const Key('app-settings-restore-backup-section'),
        title: 'Restore app data',
        subtitle:
            'Replace current local state with a previously created backup.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Restoring replaces saved servers, projects, settings, and history '
              'in the current local database.',
              key: const Key('app-settings-restore-warning'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  key: const Key('app-settings-backup-restore-s3-button'),
                  onPressed: _backupActionBusy || !s3Ready
                      ? null
                      : _restoreLatestBackupFromS3,
                  icon: _restoringFromS3
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined),
                  label: const Text('Restore latest S3 backup'),
                ),
                OutlinedButton.icon(
                  key: const Key('app-settings-backup-restore-local-button'),
                  onPressed: _backupActionBusy ? null : _restoreFromLocalCopy,
                  icon: _restoringLocal
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore),
                  label: const Text('Restore a local backup'),
                ),
              ],
            ),
            if (backupError != null) ...[
              const SizedBox(height: 10),
              Text(
                backupError,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final activeThemeMode = ref.watch(themeProvider);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // Hoisted so the `!= null` checks below promote them.
    final agentServerError = _agentServerError;
    final agentAccessError = _agentAccessError;
    final passwordError = _passwordError;

    return AppWorkspaceScaffold(
      destinations: _destinations,
      selectedIndex: _selectedDestinationIndex,
      onSelected: _selectDestination,
      navigationKeyNamespace: 'app-settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppWorkspaceHeader(
            title: _destinations[_selectedDestinationIndex].label,
            subtitle: _destinationSubtitles[_selectedDestinationIndex],
          ),
          Expanded(
            child: SingleChildScrollView(
              key: const Key('app-settings-view'),
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selectedDestinationIndex == 0)
                    AppWorkspaceSection(
                      key: const Key('app-settings-appearance-section'),
                      title: 'Theme',
                      subtitle:
                          'Choose how Deploy Dash looks on this computer.',
                      child: DropdownButtonFormField<ThemeMode>(
                        key: const Key('app-settings-theme-dropdown'),
                        initialValue: activeThemeMode,
                        decoration: const InputDecoration(labelText: 'Theme'),
                        items: const [
                          DropdownMenuItem(
                            value: ThemeMode.system,
                            child: Text('System'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.light,
                            child: Text('Light'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.dark,
                            child: Text('Dark'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          unawaited(
                            ref
                                .read(themeProvider.notifier)
                                .setThemeMode(value),
                          );
                        },
                      ),
                    ),
                  if (_selectedDestinationIndex == 1)
                    const DesktopUpdatesView(),
                  if (_selectedDestinationIndex == 2)
                    AppWorkspaceSection(
                      key: const Key('app-settings-agent-access-section'),
                      title: 'Local agent access',
                      subtitle: appSettingsAgentSectionSubtitle(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            key: const Key('app-settings-agent-access-toggle'),
                            contentPadding: EdgeInsets.zero,
                            value: _agentAccessEnabled,
                            title: const Text('Enable local agent access'),
                            subtitle: const Text(
                              'Use a localhost MCP endpoint at '
                              'http://127.0.0.1:$deployDashAgentControlPort/mcp',
                            ),
                            onChanged: _updatingAgentAccess
                                ? null
                                : (value) =>
                                      unawaited(_toggleAgentAccess(value)),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: const Key(
                              'app-settings-agent-permission-dropdown',
                            ),
                            initialValue: _agentPermissionMode,
                            decoration: const InputDecoration(
                              labelText: 'Permission mode',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: agentAccessPermissionReadOnly,
                                child: Text('Read-only'),
                              ),
                              DropdownMenuItem(
                                value: agentAccessPermissionRedeploy,
                                child: Text('Read-only + redeploy'),
                              ),
                            ],
                            onChanged:
                                !_agentAccessEnabled || _updatingAgentAccess
                                ? null
                                : (value) {
                                    if (value == null) {
                                      return;
                                    }
                                    unawaited(
                                      _changeAgentPermissionMode(value),
                                    );
                                  },
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Read-only mode includes managed PostgreSQL inspection and '
                            'bounded queries for the project you select. Only one '
                            'redeploy session can be active at a time, and agents must '
                            'use the current bearer token for redeploy actions.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          SelectableText(
                            'Endpoint: http://127.0.0.1:$deployDashAgentControlPort/mcp',
                            key: const Key('app-settings-agent-endpoint-text'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            'Session expires: ${_formatSessionExpiry(_agentSessionExpiresAt)}',
                            key: const Key(
                              'app-settings-agent-session-expiry-text',
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if ((_agentSessionToken ?? '').trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SelectableText(
                              'Session token: $_agentSessionToken',
                              key: const Key(
                                'app-settings-agent-session-token-text',
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          if (agentServerError != null &&
                              agentServerError.trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              agentServerError,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton.icon(
                                key: const Key(
                                  'app-settings-agent-issue-session-button',
                                ),
                                onPressed:
                                    !_agentAccessEnabled ||
                                        _agentPermissionMode !=
                                            agentAccessPermissionRedeploy ||
                                        _issuingAgentSession ||
                                        _revokingAgentSession ||
                                        _hasActiveAgentSession
                                    ? null
                                    : _issueSession,
                                icon: _issuingAgentSession
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.key_outlined),
                                label: const Text('Start redeploy session'),
                              ),
                              OutlinedButton.icon(
                                key: const Key(
                                  'app-settings-agent-revoke-session-button',
                                ),
                                onPressed:
                                    !_agentAccessEnabled ||
                                        _revokingAgentSession ||
                                        (_agentSessionToken ?? '')
                                            .trim()
                                            .isEmpty
                                    ? null
                                    : _revokeSession,
                                icon: _revokingAgentSession
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.cancel_outlined),
                                label: const Text('End session'),
                              ),
                            ],
                          ),
                          if (agentAccessError != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              agentAccessError,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          if (_recentAgentActions.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Recent agent actions',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            for (final entry in _recentAgentActions.take(5))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  '${entry.toolName} • ${entry.status} • ${entry.summary}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                          if (_runningAgentTasks.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Current agent activity',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            for (final entry in _runningAgentTasks.take(5))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  _formatAgentTaskSummary(entry),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                          if (_recentAgentTaskResults.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Recent redeploy results',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            for (final entry in _recentAgentTaskResults.take(5))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  _formatAgentTaskSummary(entry),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  if (_selectedDestinationIndex == 3)
                    ..._buildAppBackupSections(context),
                  if (_selectedDestinationIndex == 4)
                    AppWorkspaceSection(
                      key: const Key('app-settings-security-section'),
                      title: 'App lock password',
                      subtitle: appSettingsPasswordSectionSubtitle(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppPasswordFormField(
                            fieldKey: const Key(
                              'app-settings-password-current-field',
                            ),
                            controller: _currentPasswordController,
                            labelText: 'Current password',
                          ),
                          const SizedBox(height: 10),
                          AppPasswordFormField(
                            fieldKey: const Key(
                              'app-settings-password-new-field',
                            ),
                            controller: _newPasswordController,
                            labelText: 'New password',
                          ),
                          const SizedBox(height: 10),
                          AppPasswordFormField(
                            fieldKey: const Key(
                              'app-settings-password-confirm-field',
                            ),
                            controller: _confirmNewPasswordController,
                            labelText: 'Confirm new password',
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Existing exported or downloaded database files will still '
                            'require the old password.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            key: const Key(
                              'app-settings-password-change-button',
                            ),
                            onPressed:
                                _changingPassword ||
                                    _runningBackup ||
                                    _exporting
                                ? null
                                : _changePassword,
                            icon: _changingPassword
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.password_outlined),
                            label: const Text('Update password'),
                          ),
                          if (passwordError != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              passwordError,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (_selectedDestinationIndex == 5)
                    _PrivacySection(
                      key: const Key('app-settings-privacy-section'),
                      enabled: _telemetryEnabled,
                      updating: _updatingTelemetry,
                      error: _telemetryError,
                      onChanged: _toggleTelemetry,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Privacy destination: the live usage-reporting switch plus the
/// collected/never-collected lists, so the switch is never a blind flip.
class _PrivacySection extends StatelessWidget {
  const _PrivacySection({
    super.key,
    required this.enabled,
    required this.updating,
    required this.error,
    required this.onChanged,
  });

  final bool enabled;
  final bool updating;
  final String? error;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updateError = error;
    return AppWorkspaceSection(
      title: telemetryHelpImproveTitle(),
      subtitle: privacySectionSubtitle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('app-settings-privacy-telemetry-toggle'),
            contentPadding: EdgeInsets.zero,
            value: enabled,
            title: Text(telemetryShareSwitchLabel()),
            subtitle: Text(
              enabled
                  ? 'On: anonymous usage reporting is active.'
                  : 'Off: no further usage events leave this computer.',
            ),
            onChanged: updating ? null : onChanged,
          ),
          if (updateError != null) ...[
            const SizedBox(height: 8),
            Text(updateError, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Text(privacyCollectedTitle(), style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final kind in privacyCollectedKinds())
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $kind', style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          Text(privacyNeverCollectedTitle(), style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final kind in privacyNeverCollectedKinds())
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $kind', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

Future<String?> _pickLocalBackupExportPath(String suggestedName) async {
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Deploy Dash backup database',
        extensions: <String>['db'],
      ),
    ],
  );
  return location?.path;
}

Future<String?> _pickLocalBackupRestorePath() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Deploy Dash backup database',
        extensions: <String>['db'],
      ),
    ],
    confirmButtonText: 'Select backup',
  );
  return file?.path;
}
