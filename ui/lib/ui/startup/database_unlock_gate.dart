import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';

import '../../providers/database_unlock_provider.dart';
import '../../providers/pending_enrollment_provider.dart';
import '../../providers/server_provider.dart';
import '../../services/app_analytics_service.dart';
import '../system/app_accessibility_identifier.dart';
import '../system/app_copy.dart';
import '../system/app_forms.dart';
import '../system/app_theme.dart';
import '../system/app_window_title.dart';
import '../system/app_workspace.dart';
import 'pre_enrollment_onboarding_host.dart';
import 'restore_launch_button.dart';

typedef DatabaseExistsLoader = Future<bool> Function();
typedef PassphraseValidator = Future<bool> Function(String passphrase);
typedef BackupFormatEnforcer = Future<void> Function(String passphrase);
typedef PassphraseCreator = Future<bool> Function(String passphrase);
typedef PassphraseCreationFailureDetailsLoader = String? Function();
typedef BackupFilePicker = Future<String?> Function();
typedef DatabaseRestoreHandler =
    Future<File> Function({required String sourcePath, bool overwriteExisting});

BackupFilePicker? _debugStartupBackupFilePicker;

void debugOverrideDatabaseUnlockBackupFilePicker(BackupFilePicker? picker) {
  _debugStartupBackupFilePicker = picker;
}

class DatabaseUnlockGate extends StatefulWidget {
  const DatabaseUnlockGate({
    super.key,
    required this.childBuilder,
    this.databaseExists = appDatabaseExists,
    this.createPassphrase = createAppDatabasePassphrase,
    this.createFailureDetails = appDatabasePassphraseCreationFailureDetails,
    this.validatePassphrase = validateAppDatabasePassphrase,
    this.enforceBackupFormatVersion =
        enforceCurrentAppDatabaseBackupFormatVersion,
    this.pickBackupFile = _pickStartupBackupFile,
    this.restoreBackupFile = restoreAppDatabaseFromBackupFile,
    this.preEnrollmentServerNotifier,
  });

  final Widget Function(String passphrase) childBuilder;
  final DatabaseExistsLoader databaseExists;
  final PassphraseCreator createPassphrase;
  final PassphraseCreationFailureDetailsLoader createFailureDetails;
  final PassphraseValidator validatePassphrase;
  final BackupFormatEnforcer enforceBackupFormatVersion;
  final BackupFilePicker pickBackupFile;
  final DatabaseRestoreHandler restoreBackupFile;

  /// Test-only seam replacing the pre-enrollment wizard's check/run state.
  final ServerNotifier Function()? preEnrollmentServerNotifier;

  @override
  State<DatabaseUnlockGate> createState() => _DatabaseUnlockGateState();
}

enum _DatabaseUnlockMode { checking, onboarding, unlock, restore }

class _DatabaseUnlockGateState extends State<DatabaseUnlockGate> {
  final TextEditingController _passphraseController = TextEditingController();
  final TextEditingController _restorePathController = TextEditingController();
  final FocusNode _passphraseFocusNode = FocusNode();

  _DatabaseUnlockMode _mode = _DatabaseUnlockMode.checking;
  // Placeholder: _showRestoreScreen always overwrites this before the back
  // action can read it.
  _DatabaseUnlockMode _restoreReturnMode = _DatabaseUnlockMode.unlock;
  String? _unlockedPassphrase;

  /// The confirmation-green server awaiting its save, carried across the
  /// scope rebuild. Set when the pre-enrollment wizard enrolls, cleared
  /// when a restore installs a possibly foreign database.
  PendingEnrollment? _pendingEnrollment;
  String? _errorMessage;
  String? _statusMessage;
  bool _obscurePassphrase = true;
  bool _isSubmitting = false;
  bool _isRestoring = false;

  @override
  void initState() {
    super.initState();
    _resolveStartupMode();
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    _restorePathController.dispose();
    _passphraseFocusNode.dispose();
    super.dispose();
  }

  Future<void> _resolveStartupMode() async {
    try {
      final exists = await widget.databaseExists();
      if (!mounted) {
        return;
      }
      if (!exists) {
        // Fresh install: the onboarding funnel opens before any passphrase.
        appAnalyticsService.trackOnboardingStarted();
      }
      setState(() {
        _mode = exists
            ? _DatabaseUnlockMode.unlock
            : _DatabaseUnlockMode.onboarding;
        _statusMessage = null;
      });
    } on FileSystemException {
      if (!mounted) {
        return;
      }
      // The local data is unavailable before any attempt was made.
      appAnalyticsService.trackUnlockFailed(
        reason: UnlockFailureReason.dbMissing,
      );
      setState(() {
        _mode = _DatabaseUnlockMode.unlock;
        _errorMessage =
            'Couldn’t check the local app data. Try unlocking the app again.';
      });
    } on StateError {
      // The database bootstrap has already been disposed, so retain the safe
      // unlock path rather than claiming a fresh store can be created.
      if (!mounted) {
        return;
      }
      appAnalyticsService.trackUnlockFailed(
        reason: UnlockFailureReason.dbMissing,
      );
      setState(() {
        _mode = _DatabaseUnlockMode.unlock;
        _errorMessage =
            'Couldn’t check the local app data. Try unlocking the app again.';
      });
    }
  }

  /// Enrolls the in-wizard passphrase: creates the database with the
  /// secret the wizard collected, then unlocks into the shell with the
  /// pending pair. A refused result leaves the wizard on its step to
  /// show the creation failure where the passphrase was typed.
  Future<EnrollmentResult> _handleEnrollmentRequired(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
    String passphrase,
  ) async {
    final pendingEnrollment = PendingEnrollment(
      draft: draft,
      checkResult: checkResult,
    );
    final created = await widget.createPassphrase(passphrase);
    if (!mounted) {
      return const EnrollmentResult(enrolled: false);
    }
    if (created) {
      // Create path: the passphrase enrolled a fresh install. No backup
      // format check: a freshly created database can never carry
      // deploydash_backup_metadata, same as _submitPassphrase.
      appAnalyticsService.trackEnrollment(
        outcome: DataOperationOutcome.success,
      );
      setState(() {
        _pendingEnrollment = pendingEnrollment;
        _unlockedPassphrase = passphrase;
      });
      return const EnrollmentResult(enrolled: true);
    }
    // Creation failure reports like the unlock screen's rejected attempt.
    appAnalyticsService.trackUnlockFailed(
      reason: UnlockFailureReason.authFailed,
    );
    appAnalyticsService.trackEnrollment(outcome: DataOperationOutcome.failure);
    return EnrollmentResult(
      enrolled: false,
      failureDetails: widget.createFailureDetails(),
    );
  }

  void _showRestoreScreen() {
    setState(() {
      // Restore is reachable from unlock and the onboarding intro; back
      // returns to whichever opened it.
      _restoreReturnMode = _mode == _DatabaseUnlockMode.unlock
          ? _DatabaseUnlockMode.unlock
          : _mode;
      _mode = _DatabaseUnlockMode.restore;
      _errorMessage = null;
      _statusMessage = null;
    });
  }

  void _showBackFromRestoreScreen() {
    setState(() {
      _mode = _restoreReturnMode;
      _errorMessage = null;
      _statusMessage = null;
      _restorePathController.clear();
    });
  }

  Future<void> _selectRestoreFile() async {
    final path =
        await (_debugStartupBackupFilePicker ?? widget.pickBackupFile)();
    if (!mounted || path == null) {
      return;
    }
    setState(() {
      _restorePathController.text = path;
      _errorMessage = null;
    });
  }

  Future<void> _restoreBackup() async {
    final sourcePath = _restorePathController.text.trim();
    if (sourcePath.isEmpty) {
      setState(() {
        _errorMessage = 'Choose a downloaded backup file to restore.';
      });
      return;
    }

    setState(() {
      _isRestoring = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      await widget.restoreBackupFile(
        sourcePath: sourcePath,
        overwriteExisting: true,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _mode = _DatabaseUnlockMode.unlock;
        _isRestoring = false;
        _restorePathController.clear();
        _statusMessage = startupRestoreSuccessMessage();
        // The installed file may belong to a different install: a stashed
        // enrollment from this launch must not survive the restore.
        _pendingEnrollment = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      // A restore that fails to install leaves no usable local data. The
      // copy step never parses, so every failure here -- missing, empty, or
      // an install IO error -- reads as unavailable rather than malformed;
      // malformed content surfaces later at the format check (dbCorrupt).
      appAnalyticsService.trackUnlockFailed(
        reason: UnlockFailureReason.dbMissing,
      );
      setState(() {
        _isRestoring = false;
        _errorMessage = couldntMessage('restore that backup file', error);
      });
    }
  }

  /// Validates the unlock passphrase. Creation now happens through the
  /// in-wizard enrollment handoff, never through this submit path.
  Future<void> _submitPassphrase() async {
    final passphrase = _passphraseController.text.trim();

    if (passphrase.isEmpty) {
      setState(() {
        _errorMessage = startupPassphraseEmptyMessage();
        _statusMessage = null;
      });
      return;
    }

    setState(() {
      _errorMessage = null;
      _statusMessage = null;
      _isSubmitting = true;
    });

    final isValid = await widget.validatePassphrase(passphrase);
    if (!mounted) {
      return;
    }

    if (isValid) {
      // This is the first point since a possible startup restore
      // (DatabaseUnlockGate._restoreBackup, which copies the chosen file
      // into place before any passphrase is known) that a passphrase is
      // available to check what was actually installed.
      try {
        await widget.enforceBackupFormatVersion(passphrase);
      } catch (error) {
        if (!mounted) {
          return;
        }
        // The passphrase validated, so the file is present but unusable:
        // malformed content or a newer backup format this build refuses.
        appAnalyticsService.trackUnlockFailed(
          reason: UnlockFailureReason.dbCorrupt,
        );
        setState(() {
          _isSubmitting = false;
          _errorMessage = startupRestoreFailureMessage(error);
        });
        return;
      }
      setState(() {
        _unlockedPassphrase = passphrase;
        _isSubmitting = false;
      });
      return;
    }

    // The validator collapses wrong-passphrase and missing-file into one
    // `false`: in every case the credential step rejected the attempt.
    appAnalyticsService.trackUnlockFailed(
      reason: UnlockFailureReason.authFailed,
    );
    setState(() {
      _isSubmitting = false;
      _errorMessage = 'Incorrect passphrase.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final unlockedPassphrase = _unlockedPassphrase;
    if (unlockedPassphrase != null) {
      final pendingEnrollment = _pendingEnrollment;
      final child = widget.childBuilder(unlockedPassphrase);
      // Unlock and restore paths carry no enrollment, so their tree stays
      // exactly as before; only a fresh enrollment wraps the child.
      if (pendingEnrollment == null) {
        return child;
      }
      return ProviderScope(
        overrides: [
          pendingEnrollmentProvider.overrideWith(
            () => PendingEnrollmentNotifier(pendingEnrollment),
          ),
          // A nested scope captures ownership of every provider the child
          // scope does not override, and those build against this scope.
          // Without the passphrase here, the passphrase notifier builds
          // null and the shell opens the encrypted database unencrypted,
          // failing every read. Same value the child scope carries; the
          // unlock and restore paths have no outer scope and are
          // unaffected.
          initialDatabasePassphraseProvider.overrideWithValue(
            unlockedPassphrase,
          ),
          // Marks the session as a fresh enrollment so the shell keeps
          // the first-run wizard mounted while its first server's setup
          // is still pending.
          freshEnrollmentSessionProvider.overrideWithValue(true),
        ],
        child: child,
      );
    }

    if (_mode == _DatabaseUnlockMode.onboarding) {
      return _StartupShell(
        windowScreen: 'Connect server',
        childBuilder: (_) => PreEnrollmentOnboardingHost(
          onEnrollmentRequired: _handleEnrollmentRequired,
          onRestoreRequest: _showRestoreScreen,
          serverNotifierFactory: widget.preEnrollmentServerNotifier,
        ),
        overlayBuilder: (_) => _RestoreOverlay(
          mode: _mode,
          onShowRestore: _showRestoreScreen,
          onBackFromRestore: _showBackFromRestoreScreen,
        ),
      );
    }

    if (_mode == _DatabaseUnlockMode.checking) {
      return _StartupShell(
        windowScreen: 'Starting',
        childBuilder: (_) => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Preparing encrypted local storage...'),
            ],
          ),
        ),
      );
    }

    // Unlock-or-restore only: creation moved into the wizard's passphrase
    // step, so isCreateMode is always false down here.
    final isRestoreMode = _mode == _DatabaseUnlockMode.restore;
    final title = startupTitle(
      isCreateMode: false,
      isRestoreMode: isRestoreMode,
    );
    final description = startupDescription(
      isCreateMode: false,
      isRestoreMode: isRestoreMode,
    );

    return _StartupShell(
      windowScreen: isRestoreMode ? 'Restore app data' : 'Unlock',
      childBuilder: (shellContext) => AppFocusedFlowScaffold(
        key: const Key('database-startup-focused-flow'),
        productName: 'Deploy Dash',
        title: title,
        subtitle: description,
        icon: Icons.lock_open,
        maxWidth: 520,
        actions: [
          AppAccessibilityIdentifier(
            identifier: isRestoreMode
                ? 'database-restore-submit'
                : 'database-passphrase-submit',
            child: FilledButton.icon(
              key: Key(
                isRestoreMode
                    ? 'database-restore-submit'
                    : 'database-passphrase-submit',
              ),
              onPressed: isRestoreMode
                  ? (_isRestoring ? null : _restoreBackup)
                  : (_isSubmitting ? null : _submitPassphrase),
              icon: isRestoreMode
                  ? (_isRestoring
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.restore))
                  : _isSubmitting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(
                isRestoreMode
                    ? startupRestoreButtonLabel(_isRestoring)
                    : startupPrimaryButtonLabel(
                        isCreateMode: false,
                        isSubmitting: _isSubmitting,
                      ),
              ),
            ),
          ),
        ],
        child: AppFormSection(
          children: [
            if (isRestoreMode) ...[
              AppTextFormField(
                fieldKey: const Key('database-restore-path-field'),
                controller: _restorePathController,
                labelText: 'Backup file',
                readOnly: true,
                enabled: !_isRestoring,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('database-restore-browse-button'),
                  onPressed: _isRestoring ? null : _selectRestoreFile,
                  icon: const Icon(Icons.folder_open),
                  label: Text(startupBrowseBackupButtonLabel()),
                ),
              ),
            ] else ...[
              AppTextFormField(
                fieldKey: const Key('database-passphrase-field'),
                controller: _passphraseController,
                labelText: 'Passphrase',
                obscureText: _obscurePassphrase,
                enabled: !_isSubmitting,
                focusNode: _passphraseFocusNode,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_errorMessage == null) {
                    return;
                  }
                  setState(() {
                    _errorMessage = null;
                  });
                },
                onFieldSubmitted: (_) => _submitPassphrase(),
                suffixIcon: IconButton(
                  key: const Key('database-passphrase-visibility'),
                  tooltip: _obscurePassphrase
                      ? 'Show passphrase'
                      : 'Hide passphrase',
                  onPressed: () => setState(() {
                    _obscurePassphrase = !_obscurePassphrase;
                  }),
                  icon: Icon(
                    _obscurePassphrase
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                ),
              ),
            ],
            if (_statusMessage case final statusMessage?)
              Text(
                statusMessage,
                key: const Key('database-startup-status'),
                style: TextStyle(
                  color: Theme.of(shellContext).colorScheme.primary,
                ),
              ),
            if (_errorMessage case final errorMessage?)
              Text(
                errorMessage,
                key: const Key('database-passphrase-error'),
                style: TextStyle(
                  color: Theme.of(shellContext).colorScheme.error,
                ),
              ),
          ],
        ),
      ),
      overlayBuilder: (_) => _RestoreOverlay(
        mode: _mode,
        onShowRestore: _showRestoreScreen,
        onBackFromRestore: _showBackFromRestoreScreen,
      ),
    );
  }
}

/// The quiet bottom-left restore entry, shared by the passphrase screens
/// and the pre-enrollment wizard at the same placement.
class _RestoreOverlay extends StatelessWidget {
  const _RestoreOverlay({
    required this.mode,
    required this.onShowRestore,
    required this.onBackFromRestore,
  });

  final _DatabaseUnlockMode mode;
  final VoidCallback onShowRestore;
  final VoidCallback onBackFromRestore;

  @override
  Widget build(BuildContext context) {
    // The unlock screen keeps the overlay entry. Onboarding brings its
    // own: the wizard's intro step renders it, so later steps never do.
    final showRestoreButton = mode == _DatabaseUnlockMode.unlock;
    final showBackButton = mode == _DatabaseUnlockMode.restore;
    if (!showRestoreButton && !showBackButton) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 24,
      bottom: 24,
      child: showRestoreButton
          ? RestoreLaunchButton(onPressed: onShowRestore)
          : TextButton.icon(
              key: const Key('database-restore-back-button'),
              onPressed: onBackFromRestore,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
    );
  }
}

class _StartupShell extends StatelessWidget {
  const _StartupShell({
    required this.windowScreen,
    required this.childBuilder,
    this.overlayBuilder,
  });

  final String windowScreen;
  final WidgetBuilder childBuilder;
  final WidgetBuilder? overlayBuilder;

  @override
  Widget build(BuildContext context) {
    final baseTheme = yaruLight;
    final darkTheme = yaruDark;
    return AppWindowTitle(
      screen: windowScreen,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildDeployDashTheme(baseTheme),
        darkTheme: buildDeployDashTheme(darkTheme),
        themeMode: ThemeMode.system,
        home: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: YaruWindowTitleBar(
              title: const Text('Deploy Dash'),
              border: const BorderSide(color: Color(0x1A000000), width: 0.5),
            ),
          ),
          body: Stack(
            children: [
              Builder(builder: childBuilder),
              if (overlayBuilder case final overlayBuilder?)
                Builder(builder: overlayBuilder),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> _pickStartupBackupFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Deploy Dash backup database',
        extensions: <String>['db'],
      ),
    ],
  );
  return file?.path;
}
