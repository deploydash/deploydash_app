import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as path;
import 'package:yaru/yaru.dart';

import '../../models/app_user_attribute.dart';
import '../../providers/pending_enrollment_provider.dart';
import '../../providers/server_list_provider.dart';
import '../../providers/server_provider.dart';
import '../../providers/telemetry_settings_provider.dart';
import '../../services/app_analytics_service.dart';
import '../../services/managed_ssh_key_service.dart';
import '../../utils/host_format.dart';
import '../../utils/payload_codecs.dart';
import '../system/app_accessibility_identifier.dart';
import '../system/app_rows.dart';
import '../system/app_copy.dart';
import '../system/app_dialogs.dart';
import '../system/app_forms.dart';
import '../system/app_sections.dart';
import '../system/app_theme.dart';
import '../system/app_window_title.dart';
import '../system/app_workspace.dart';
import '../startup/restore_launch_button.dart';
import 'management/system_ssh_key_import.dart';
import 'server_onboarding_security.dart';
import 'server_onboarding_view_logic.dart';

enum _OnboardingStep {
  intro,
  credentials,
  confirmation,
  setupProgress,
  services,
}

class ServerOnboardingView extends ConsumerStatefulWidget {
  const ServerOnboardingView({
    super.key,
    required this.onSavePendingServer,
    required this.onUpdatePendingServer,
    required this.onAdoptManagedIdentity,
    this.firstRun = true,
    this.initialStep,
    this.retryServerId,
    this.pendingEnrollment,
    this.onEnrollmentRequired,
    this.onRestoreRequest,
    this.onCompleteServiceSelection,
  }) : assert(
         retryServerId == null || pendingEnrollment == null,
         'retry and pending enrollment are exclusive resume paths',
       ),
       assert(
         onEnrollmentRequired == null || pendingEnrollment == null,
         'the pre-enrollment wizard never carries a pending enrollment',
       );

  /// Persists the checked bootstrap draft under `setup_in_progress` before
  /// provisioning starts, returning the saved server for the handoff below.
  final Future<Server> Function(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
  )
  onSavePendingServer;

  /// Rewrites the bootstrap identity of the record this opening saved.
  ///
  /// The wizard saves once per opening and updates on every later Finish,
  /// so reprovisioning the same record never creates a duplicate, and
  /// credential edits made after the first save still apply.
  final Future<Server> Function({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  })
  onUpdatePendingServer;

  /// Pivots the early-saved server to its verified managed identity once
  /// setup succeeds, scrubbing the bootstrap credential it was saved with.
  final Future<void> Function({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  })
  onAdoptManagedIdentity;
  final bool firstRun;
  final String? initialStep;

  /// Retries setup for an early-saved server instead of starting a new one.
  ///
  /// When set, the wizard opens directly on setup progress and provisions
  /// from the stored record and its saved bootstrap credential. The Server
  /// Management incomplete card and the Home resume entry are the callers,
  /// and both render solely for servers the catalog reports as
  /// setup-pending.
  final String? retryServerId;

  /// Resumes a confirmation-green server that enrolled before the save.
  ///
  /// When set, the wizard opens directly on setup progress and runs the
  /// save-plus-provisioning Finish path for this already-checked pair, as
  /// if Finish setup had just been clicked on the review step. The save
  /// clears the provider copy so a remount can never save twice.
  final PendingEnrollment? pendingEnrollment;

  /// Pauses the wizard at confirmation-green for enrollment.
  ///
  /// When set, Finish setup opens the create-password modal instead of
  /// saving and provisioning, and the modal hands the checked draft,
  /// result, and passphrase to this callback. A refused result keeps the
  /// modal open with the creation failure. The pre-enrollment host is the
  /// only caller: nothing is persisted before the passphrase exists, so
  /// there is no record to provision against yet.
  final Future<EnrollmentResult> Function(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
    String passphrase,
  )?
  onEnrollmentRequired;

  /// Offers the quiet restore entry on the intro screen only.
  ///
  /// When set, the intro shows the bottom-left restore button; later
  /// steps never do. Null for post-unlock openings, where no database
  /// needs restoring. The pre-enrollment host is the only caller.
  final VoidCallback? onRestoreRequest;
  final Future<void> Function({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  })?
  onCompleteServiceSelection;

  @override
  ConsumerState<ServerOnboardingView> createState() =>
      _ServerOnboardingViewState();
}

class _ServerOnboardingViewState extends ConsumerState<ServerOnboardingView> {
  final _fields = _CredentialFields();

  ServerAuthMethod _authMethod = ServerAuthMethod.password;
  String? _importedPrivateKey;
  String? _importedPublicKey;
  _OnboardingStep _step = _OnboardingStep.intro;
  bool _isSaving = false;

  /// Latches the connection check from tap through navigation. The
  /// provider's loading flag drops as soon as the check resolves, which
  /// is a frame before the plan load finishes and the wizard advances;
  /// without this latch the button flickers back to clickable in between.
  bool _isChecking = false;
  bool _isFinishingServices = false;
  String? _localError;
  ServerDraft? _latestDraft;
  Map<String, dynamic>? _latestResult;

  /// The record this opening saved. Later finishes update it instead of
  /// saving again, so a retry never creates a duplicate server.
  String? _pendingServerId;

  /// Setup attempts started from this wizard opening.
  int _setupAttempt = 0;

  /// The analytics service captured at init. Reporting must not touch `ref`
  /// (Riverpod forbids reads once the widget starts unmounting), so the
  /// dispose-time abandon row goes through this handle instead.
  late final AppAnalyticsService _analyticsService;

  /// Whether any setup run in this wizard opening succeeded. Guards the
  /// abandon row: leaving after success is finishing, not abandoning.
  bool _setupSucceeded = false;

  /// Whether services selection completed in this wizard opening. Guards the
  /// completion event: closing afterwards is finishing, anything else is not.
  bool _servicesCompleted = false;

  /// The baseline checkpoints one successful setup run reports, in order.
  static const _baselineCheckpoints = <OnboardingStep>[
    OnboardingStep.bootstrap,
    OnboardingStep.ubuntuLoginVerified,
    OnboardingStep.sshHardened,
    OnboardingStep.firewallBaselined,
    OnboardingStep.fail2ban,
    OnboardingStep.autoUpdates,
    OnboardingStep.dockerPinned,
    OnboardingStep.railpackPinned,
    OnboardingStep.ownershipHandoff,
  ];

  /// Reports one funnel row. Single seam so the hook sites cannot drift onto
  /// different providers or method spellings. Analytics calls never throw by
  /// construction (backends contain their own failures), so reporting cannot
  /// break the flow it observes.
  void _trackOnboardingStep(
    OnboardingStep step, {
    required bool succeeded,
    int? attempt,
  }) {
    _analyticsService.trackOnboardingStep(
      step: step,
      succeeded: succeeded,
      attempt: attempt ?? _setupAttempt,
    );
  }

  /// Reports a successful setup run: every baseline checkpoint plus the
  /// completion marker, all carrying the run's attempt number.
  void _trackSuccessfulSetup() {
    for (final step in _baselineCheckpoints) {
      _trackOnboardingStep(step, succeeded: true);
    }
    _trackOnboardingStep(OnboardingStep.completed, succeeded: true);
  }

  // coverage-gate: onboarding_completion_report
  /// The credential shape this opening ran with, for the completion event.
  /// Always known (the form defaults to password); the event keeps it
  /// optional for flows that close before credentials exist.
  OnboardingAuthProvider get _onboardingAuthProvider {
    return _authMethod == ServerAuthMethod.sshKey
        ? OnboardingAuthProvider.sshKey
        : OnboardingAuthProvider.password;
  }

  /// The wizard screen this opening stands on, for the completion event.
  OnboardingStage get _onboardingStage {
    return switch (_step) {
      _OnboardingStep.intro => OnboardingStage.intro,
      _OnboardingStep.credentials => OnboardingStage.credentials,
      _OnboardingStep.confirmation => OnboardingStage.confirmation,
      _OnboardingStep.setupProgress => OnboardingStage.setupProgress,
      _OnboardingStep.services => OnboardingStage.services,
    };
  }

  /// Reports this wizard opening closing: success when services selection
  /// completed, failure otherwise. Exactly one row per opening, through the
  /// init-captured handle like the abandon row. Success also records the
  /// onboarding activation milestone alongside the event.
  void _trackOnboardingCompletion() {
    if (_servicesCompleted) {
      _analyticsService.trackOnboardingEvent(
        outcome: DataOperationOutcome.success,
        provider: _onboardingAuthProvider,
        stage: _onboardingStage,
      );
      _analyticsService.setUserAttribute(
        AppUserAttribute.hasCompletedOnboarding,
        'true',
      );
    } else {
      _analyticsService.trackOnboardingEvent(
        outcome: DataOperationOutcome.failure,
        provider: _onboardingAuthProvider,
        stage: _onboardingStage,
      );
    }
  }
  // end coverage-gate

  @override
  void initState() {
    super.initState();
    _analyticsService = ref.read(appAnalyticsServiceProvider);
    final retryServerId = widget.retryServerId;
    final pendingEnrollment = widget.pendingEnrollment;
    if (retryServerId != null) {
      _step = _OnboardingStep.setupProgress;
      _isSaving = true;
      scheduleMicrotask(() => _runSetupRetry(retryServerId));
    } else if (pendingEnrollment != null) {
      _latestDraft = pendingEnrollment.draft;
      _latestResult = pendingEnrollment.checkResult;
      _step = _OnboardingStep.setupProgress;
      _isSaving = true;
      scheduleMicrotask(() => _saveServer());
    } else if (widget.initialStep == 'services_selection') {
      _step = _OnboardingStep.services;
    } else if (!widget.firstRun) {
      _step = _OnboardingStep.credentials;
    }
  }

  @override
  void dispose() {
    if (!_setupSucceeded) {
      // The wizard closed without setup ever succeeding. The zero attempt
      // marks the abandon; a genuine step failure always carries >= 1.
      // Goes through the init-captured handle: `ref` is unreadable here.
      _trackOnboardingStep(
        OnboardingStep.abandoned,
        succeeded: false,
        attempt: 0,
      );
    }
    // coverage-gate: onboarding_completion_dispose
    _trackOnboardingCompletion();
    // end coverage-gate
    _fields.dispose();
    super.dispose();
  }

  ServerDraft? _buildDraftFromForm() {
    final formState = _fields.formKey.currentState;
    if (formState == null || !formState.validate()) {
      return null;
    }
    final port = int.parse(_fields.port.text.trim());
    return ServerDraft(
      name: _fields.serverName.text.trim(),
      host: normalizeHostInput(_fields.host.text),
      port: port,
      sshUser: _fields.user.text.trim(),
      authMethod: _authMethod,
      sshPassword: _authMethod == ServerAuthMethod.password
          ? _fields.password.text.trim()
          : null,
      privateKey: _authMethod == ServerAuthMethod.sshKey
          ? _importedPrivateKey
          : null,
      publicKey: _authMethod == ServerAuthMethod.sshKey
          ? _importedPublicKey
          : null,
    );
  }

  ServerDraft? _validatedDraftForConnection() {
    final draft = _buildDraftFromForm();
    if (draft == null) {
      return null;
    }
    final draftPassword = draft.sshPassword;
    if (draft.authMethod == ServerAuthMethod.password &&
        (draftPassword == null || draftPassword.isEmpty)) {
      setState(() {
        _localError = 'Password authentication requires a password.';
      });
      return null;
    }
    if (draft.authMethod == ServerAuthMethod.sshKey &&
        !hasServerDraftPrivateKey(draft)) {
      setState(() {
        _localError = 'SSH key authentication requires a private key file.';
      });
      return null;
    }
    return draft;
  }

  Future<bool> _confirmHostKeyChange(ServerState state) async {
    final details = hostKeyConfirmationDetails(
      state,
      fallbackHost: _fields.host.text.trim(),
      fallbackPort: _fields.port.text.trim(),
    );
    final host = details.host;
    final port = details.port;
    final oldFingerprint = details.oldFingerprint;
    final newFingerprint = details.newFingerprint;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AppDialogScaffold(
          key: const Key('server-host-key-change-dialog'),
          title: 'Confirm this server change',
          description:
              'Deploy Dash sees a different identity for $host:$port than it '
              'saw before. This is normal after rebuilding a server. '
              'Continue only if you expected this change.',
          actions: [
            TextButton(
              key: const Key('server-host-key-change-cancel-button'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('server-host-key-change-confirm-button'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('Saved fingerprint: $oldFingerprint'),
              const SizedBox(height: 8),
              SelectableText('New fingerprint: $newFingerprint'),
            ],
          ),
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _runConnectionCheck() async {
    final draft = _validatedDraftForConnection();
    if (draft == null) {
      return;
    }

    setState(() {
      _localError = null;
      _isChecking = true;
    });
    ref.read(serverProvider.notifier).reset();
    await ref
        .read(serverProvider.notifier)
        .checkServer(
          host: draft.host,
          port: draft.port,
          username: draft.sshUser,
          password: draft.sshPassword,
          privateKey: draft.privateKey,
        );
    final state = ref.read(serverProvider);
    if (!mounted) {
      return;
    }

    if (state.result != null) {
      await ref.read(serverProvider.notifier).loadSetupPlan();
      if (!mounted) {
        return;
      }
      setState(() {
        _latestDraft = draft;
        _latestResult = state.result;
        _isChecking = false;
        _step = _OnboardingStep.confirmation;
      });
      return;
    }

    setState(() {
      _localError = null;
      _isChecking = false;
    });
  }

  Future<void> _acceptNewHostKeyAndRetry() async {
    final draft = _validatedDraftForConnection();
    if (draft == null) {
      return;
    }
    final confirmed = await _confirmHostKeyChange(ref.read(serverProvider));
    _trackOnboardingStep(OnboardingStep.hostkeyMismatch, succeeded: confirmed);
    if (!mounted || !confirmed) {
      return;
    }

    setState(() {
      _localError = null;
    });
    ref.read(serverProvider.notifier).reset();

    final refreshed = await ref
        .read(serverProvider.notifier)
        .refreshServerHostKey(
          host: draft.host,
          port: draft.port,
          username: draft.sshUser,
        );
    if (!mounted) {
      return;
    }
    if (!refreshed) {
      setState(() {
        _localError =
            ref.read(serverProvider).error ??
            'Unable to accept new host key. Please retry.';
      });
      return;
    }

    await _runConnectionCheck();
  }

  Future<void> _saveServer() async {
    final draft = _latestDraft;
    final result = _latestResult;
    if (draft == null || result == null) {
      return;
    }

    final compatibility = _compatibilityFromResult(result);
    if (!_compatibilityPassed(compatibility)) {
      setState(() {
        _localError = _compatibilitySummary(compatibility);
      });
      return;
    }

    if (widget.onEnrollmentRequired != null) {
      // Pre-enrollment: Finish only opens the create-password modal.
      // Nothing is persisted until the modal's own action enrolls.
      await _showEnrollmentDialog();
      return;
    }

    setState(() {
      _isSaving = true;
      _localError = null;
      _step = _OnboardingStep.setupProgress;
    });
    late final Server pendingServer;
    try {
      final existingId = _pendingServerId;
      pendingServer = existingId == null
          ? await widget.onSavePendingServer(draft, result)
          : await widget.onUpdatePendingServer(
              serverId: existingId,
              draft: draft,
              checkResult: result,
            );
      _pendingServerId = pendingServer.id;
      if (widget.pendingEnrollment != null) {
        // The enrolled save landed: drop the provider copy so a remount
        // opens a blank wizard instead of saving a second record.
        ref.read(pendingEnrollmentProvider.notifier).clear();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      // Nothing provisioned yet: back to review with the save error rather
      // than the progress view, which would promise work never started.
      setState(() {
        _isSaving = false;
        _step = _OnboardingStep.confirmation;
        _localError = 'Couldn’t save this server: $error';
      });
      return;
    }
    await _provisionAndAdopt(draft: draft, pendingServerId: pendingServer.id);
  }

  /// Opens the create-password modal over the review step. The draft and
  /// result are captured here: the review behind the modal cannot change
  /// while it is open, so the pair the modal enrolls is the pair the user
  /// reviewed. [_saveServer] guarantees both are non-null on this path.
  Future<void> _showEnrollmentDialog() async {
    final draft = _latestDraft!;
    final result = _latestResult!;
    final onEnrollmentRequired = widget.onEnrollmentRequired!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _EnrollmentDialog(
        onSubmit: (passphrase) =>
            onEnrollmentRequired(draft, result, passphrase),
      ),
    );
  }

  /// Retries setup for an early-saved server from its stored credentials.
  ///
  /// Re-resolves the record and payload on every run, so a server deleted
  /// or completed out from under the wizard -- or a retry aimed at a
  /// healthy server -- fails loudly instead of reprovisioning the wrong
  /// machine.
  Future<void> _runSetupRetry(String serverId) async {
    final catalog = ref.read(serverCatalogProvider);
    final server = catalog.servers
        .where((candidate) => candidate.id == serverId)
        .firstOrNull;
    if (server == null || !catalog.isServerSetupPending(serverId)) {
      setState(() {
        _isSaving = false;
        _localError = server == null
            ? 'This server is no longer saved. Add it again to set it up.'
            : 'This server already finished setup.';
      });
      return;
    }
    final payload = await ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (!mounted) {
      return;
    }
    if (payload == null) {
      setState(() {
        _isSaving = false;
        _localError =
            'Server credentials are incomplete. Remove this server and add it again.';
      });
      return;
    }
    final draft = buildRetryBootstrapDraft(
      server: server,
      connectionPayload: payload,
    );
    await _provisionAndAdopt(draft: draft, pendingServerId: serverId);
  }

  void _retryCurrentSetup() {
    final retryServerId = widget.retryServerId;
    if (retryServerId != null) {
      unawaited(_runSetupRetry(retryServerId));
    } else {
      unawaited(_saveServer());
    }
  }

  /// Provisions [draft] and pivots the early-saved record to the verified
  /// managed identity. Shared by the first setup run and every retry.
  Future<void> _provisionAndAdopt({
    required ServerDraft draft,
    required String pendingServerId,
  }) async {
    try {
      // A new attempt per save. Setup is additive: an existing ubuntu
      // account keeps its SSH keys, so there is no refusal-and-retry path.
      // Counted first so a failure before SSH still reports its run.
      _setupAttempt += 1;
      final managedKeyPair = await ref
          .read(managedSshKeyServiceProvider)
          .createKeyPair(identifier: draft.name);
      final managedDraft = buildManagedDraft(
        bootstrapDraft: draft,
        managedKeyPair: managedKeyPair,
      );
      final managedConnection = buildManagedConnectionPayload(managedDraft);
      final settings = buildManagedSetupSettings(
        bootstrapDraft: draft,
        managedDraft: managedDraft,
      );
      await ref
          .read(serverProvider.notifier)
          .setupServer(
            host: draft.host,
            port: draft.port,
            username: draft.sshUser,
            password: draft.sshPassword,
            privateKey: draft.privateKey,
            managedConnection: managedConnection,
            settings: settings,
            dryRun: false,
          );
      final setupState = ref.read(serverProvider);
      if (setupState.setupResult == null ||
          setupState.setupResult?['status'] != 'success') {
        // Only the checkpoint the backend names by code is reported; an
        // unmappable failure (network, packages, cancellation, consent
        // refusal) reports nothing rather than a guessed step.
        final failedStep = onboardingFailedStepForCode(
          setupState.errorPayload?['code']?.toString(),
        );
        if (failedStep != null) {
          _trackOnboardingStep(failedStep, succeeded: false);
        }
        // The record stays setup-incomplete even when the failure names no
        // checkpoint: count the run, not just the mappable step.
        _analyticsService.trackSetupIncomplete(attempt: _setupAttempt);
        if (!mounted) {
          return;
        }
        setState(() {
          _localError = onboardingSetupFailureSummary(
            error: setupState.error,
            errorPayload: setupState.errorPayload,
            setupResult: setupState.setupResult,
          );
        });
        return;
      }
      _setupSucceeded = true;
      _trackSuccessfulSetup();
      final managedConnectionResult =
          setupState.setupResult?['managed_connection'] as Map?;
      final savedDraft = buildSavedManagedDraft(
        managedDraft: managedDraft,
        managedConnectionResult: managedConnectionResult
            ?.cast<String, dynamic>(),
        // coverage-gate: onboarding_managed_password_threading
        managedUserPassword: managedUserPasswordFromSetupResult(
          setupState.setupResult,
        ),
        // end coverage-gate
      );
      await widget.onAdoptManagedIdentity(
        serverId: pendingServerId,
        sshUser: savedDraft.sshUser,
        authMethod: savedDraft.authMethod,
        privateKey: savedDraft.privateKey,
        publicKey: savedDraft.publicKey,
        managedUserPassword: savedDraft.managedUserPassword,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _step = _OnboardingStep.services;
      });
    } catch (error) {
      // Key generation, setup, and handoff failures alike: the record is
      // saved and unfinished, so the run counts as incomplete.
      _analyticsService.trackSetupIncomplete(attempt: _setupAttempt);
      if (!mounted) {
        return;
      }
      final setupState = ref.read(serverProvider);
      setState(() {
        _step = _OnboardingStep.setupProgress;
        _localError = onboardingSetupFailureSummary(
          error: error.toString(),
          errorPayload: setupState.errorPayload,
          setupResult: setupState.setupResult,
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _completeServiceSelection({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  }) async {
    if (_isFinishingServices) {
      return;
    }
    setState(() {
      _isFinishingServices = true;
      _localError = null;
    });
    try {
      final completeServiceSelection = widget.onCompleteServiceSelection;
      if (completeServiceSelection != null) {
        await completeServiceSelection(
          enableEmailAccounts: enableEmailAccounts,
          enableDomains: enableDomains,
          enableDatabases: enableDatabases,
          postgresVersion: postgresVersion,
          postgresExtensions: postgresExtensions,
        );
        // coverage-gate: onboarding_services_completed
        // Set before the mounted checks below: unmounting fires dispose,
        // which reads this flag to close the completion funnel.
        _servicesCompleted = true;
        // end coverage-gate
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _localError = 'Failed to complete service selection: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isFinishingServices = false;
        });
      }
    }
  }

  Future<void> _pickSshKeyPath() async {
    final file = await openFile(confirmButtonText: 'Select key');
    if (!mounted || file == null) {
      return;
    }
    try {
      ImportedSshKeyFile? imported;
      try {
        imported = await readImportedSshKeyFile(file.path);
      } on FormatException {
        // Empty private key: today's soft-null path (D-69) — the shared
        // reader throws for empty, but this view nulls instead of erroring.
        // The sibling .pub is still picked up below, exactly as when the
        // private read empty.
        imported = null;
      }
      String? publicKey = imported?.publicKey;
      if (imported == null) {
        final siblingPublicKey = File('${file.path}.pub');
        if (await siblingPublicKey.exists()) {
          final trimmed = (await siblingPublicKey.readAsString()).trim();
          if (trimmed.isNotEmpty) {
            publicKey = trimmed;
          }
        }
      }
      setState(() {
        _fields.keyPath.text = imported?.fileName ?? path.basename(file.path);
        _importedPrivateKey = imported?.privateKey;
        _importedPublicKey = publicKey;
        _localError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _localError = 'Failed to import SSH private key: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverState = ref.watch(serverProvider);
    final localError = _localError;
    if (_step == _OnboardingStep.intro) {
      // The first screen stands alone, centered like the restore screen,
      // instead of sitting in the workspace list with the later steps.
      return AppWindowTitle(
        screen: 'Connect server',
        child: _IntroScreen(
          onStart: () {
            setState(() => _step = _OnboardingStep.credentials);
          },
          onRestoreRequest: widget.onRestoreRequest,
        ),
      );
    }
    if (_step == _OnboardingStep.confirmation) {
      // The third screen matches the first two: the same centered flow.
      return AppWindowTitle(
        screen: 'Review server',
        child: _ReviewScreen(
          serverState: serverState,
          latestResult: _latestResult,
          isSaving: _isSaving,
          localError: _localError,
          onBack: () {
            setState(() => _step = _OnboardingStep.credentials);
          },
          onSave: _saveServer,
        ),
      );
    }
    if (_step == _OnboardingStep.credentials) {
      // The second screen matches the first: the same centered flow.
      return AppWindowTitle(
        screen: 'Server details',
        child: _CredentialsScreen(
          fields: _fields,
          authMethod: _authMethod,
          isSaving: _isSaving,
          isChecking: _isChecking,
          serverState: serverState,
          localError: _localError,
          onAuthMethodChanged: (method) {
            setState(() {
              _authMethod = method;
              _localError = null;
            });
          },
          onPickKey: _pickSshKeyPath,
          onCheckConnection: _runConnectionCheck,
          onAcceptHostKey: _acceptNewHostKeyAndRetry,
        ),
      );
    }
    final setupState = _setupRunState(
      isSaving: _isSaving,
      serverState: serverState,
      localError: localError,
    );
    return AppWindowTitle(
      screen: switch (_step) {
        _OnboardingStep.intro => 'Connect server',
        _OnboardingStep.credentials => 'Server details',
        _OnboardingStep.confirmation => 'Review server',
        _OnboardingStep.setupProgress => onboardingSetupProgressTitle(
          isRunning: setupState.isRunning,
          hasError: setupState.hasError,
        ),
        _OnboardingStep.services => 'Choose services',
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        children: [
          if (_step == _OnboardingStep.setupProgress)
            _SetupProgressStep(
              serverState: serverState,
              isSaving: _isSaving,
              localError: _localError,
              onRetry: _retryCurrentSetup,
              showBackToReview:
                  widget.retryServerId == null &&
                  widget.pendingEnrollment == null,
              onBackToReview: () {
                setState(() => _step = _OnboardingStep.confirmation);
              },
            ),
          if (_step == _OnboardingStep.services)
            _ServicesStep(
              isFinishing: _isFinishingServices,
              onComplete: _completeServiceSelection,
            ),
          if (_step != _OnboardingStep.setupProgress &&
              localError != null &&
              localError != serverState.error) ...[
            const SizedBox(height: 12),
            _ErrorCard(message: localError),
          ],
        ],
      ),
    );
  }
}

/// Text controllers and focus nodes for the credential step. They live in
/// [_ServerOnboardingViewState] so typed values survive a trip forward to the
/// review step and back, and are grouped here so [_CredentialForm] takes one
/// parameter rather than twelve.
class _CredentialFields {
  final formKey = GlobalKey<FormState>();
  final serverName = TextEditingController();
  final host = TextEditingController();
  final port = TextEditingController(text: '22');
  final user = TextEditingController(text: 'ubuntu');
  final password = TextEditingController();
  final keyPath = TextEditingController();
  final serverNameFocus = FocusNode();
  final hostFocus = FocusNode();
  final portFocus = FocusNode();
  final userFocus = FocusNode();
  final passwordFocus = FocusNode();

  void dispose() {
    serverName.dispose();
    host.dispose();
    port.dispose();
    user.dispose();
    password.dispose();
    keyPath.dispose();
    serverNameFocus.dispose();
    hostFocus.dispose();
    portFocus.dispose();
    userFocus.dispose();
    passwordFocus.dispose();
  }
}

class _CredentialsScreen extends StatelessWidget {
  const _CredentialsScreen({
    required this.fields,
    required this.authMethod,
    required this.isSaving,
    required this.isChecking,
    required this.serverState,
    required this.localError,
    required this.onAuthMethodChanged,
    required this.onPickKey,
    required this.onCheckConnection,
    required this.onAcceptHostKey,
  });

  final _CredentialFields fields;
  final ServerAuthMethod authMethod;
  final bool isSaving;
  final bool isChecking;
  final ServerState serverState;
  final String? localError;
  final ValueChanged<ServerAuthMethod> onAuthMethodChanged;
  final VoidCallback onPickKey;
  final VoidCallback onCheckConnection;
  final VoidCallback onAcceptHostKey;

  @override
  Widget build(BuildContext context) {
    final hostKeyMismatch = hasHostKeyMismatch(serverState);
    return AppFocusedFlowScaffold(
      key: const Key('server-credentials-flow'),
      title: 'Server details',
      subtitle:
          'Enter the details Deploy Dash needs to sign in and review this server.',
      icon: Icons.dns_outlined,
      maxWidth: 520,
      // The primary actions pin to the footer like the intro's: the
      // form can scroll under them on short screens.
      actions: [
        AppAccessibilityIdentifier(
          identifier: 'server-check-button',
          child: FilledButton(
            key: const Key('server-check-button'),
            onPressed: (isSaving || isChecking || serverState.isLoading)
                ? null
                : onCheckConnection,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isChecking || serverState.isLoading) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  onboardingCheckConnectionLabel(
                    isLoading: isChecking || serverState.isLoading,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!serverState.isLoading && hostKeyMismatch)
          OutlinedButton(
            key: const Key('server-accept-host-key-button'),
            onPressed: (isSaving || serverState.isLoading)
                ? null
                : onAcceptHostKey,
            child: const Text('Review change'),
          ),
      ],
      child: Form(
        key: fields.formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppFormSection(
              title: 'Connection',
              description:
                  'Choose a friendly name for this server, then enter the IP address or hostname Deploy Dash should connect to.',
              children: [
                AppTextFormField(
                  key: const Key('server-name-field'),
                  controller: fields.serverName,
                  focusNode: fields.serverNameFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => fields.hostFocus.requestFocus(),
                  labelText: 'Server name',
                  hintText: 'Production web server',
                  validator: _validateServerDisplayName,
                ),
                AppTextFormField(
                  key: const Key('server-host-field'),
                  controller: fields.host,
                  focusNode: fields.hostFocus,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => fields.portFocus.requestFocus(),
                  labelText: 'Server address',
                  hintText: '203.0.113.10',
                  validator: _validateHost,
                ),
                Row(
                  children: [
                    Expanded(
                      child: AppNumberFormField(
                        key: const Key('server-port-field'),
                        controller: fields.port,
                        focusNode: fields.portFocus,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            fields.userFocus.requestFocus(),
                        labelText: 'SSH port',
                        validator: _validatePort,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppTextFormField(
                        key: const Key('server-user-field'),
                        controller: fields.user,
                        focusNode: fields.userFocus,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            fields.passwordFocus.requestFocus(),
                        labelText: 'Username',
                        validator: (value) =>
                            _validateRequired(value, 'Username'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            AppFormSection(
              title: 'Sign-in method',
              children: [
                SegmentedButton<ServerAuthMethod>(
                  segments: const [
                    ButtonSegment(
                      value: ServerAuthMethod.password,
                      label: Text('Password'),
                    ),
                    ButtonSegment(
                      value: ServerAuthMethod.sshKey,
                      label: Text('SSH key'),
                    ),
                  ],
                  selected: {authMethod},
                  onSelectionChanged: (selection) =>
                      onAuthMethodChanged(selection.first),
                ),
                if (authMethod == ServerAuthMethod.password)
                  AppPasswordFormField(
                    key: const Key('server-password-field'),
                    controller: fields.password,
                    focusNode: fields.passwordFocus,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => onCheckConnection(),
                    labelText: 'Password',
                    hintText: '••••••••',
                    validator: (value) =>
                        authMethod == ServerAuthMethod.password
                        ? _validateRequired(value, 'Password')
                        : null,
                  ),
                if (authMethod == ServerAuthMethod.sshKey)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final keyField = AppTextFormField(
                        key: const Key('server-key-path-field'),
                        controller: fields.keyPath,
                        enabled: false,
                        labelText: 'Private key',
                        hintText: 'No private key imported yet',
                        helperText:
                            'Deploy Dash reads the file once, stores the key encrypted, and uses it from memory at runtime.',
                        helperMaxLines: 3,
                      );
                      final importButton = OutlinedButton(
                        key: const Key('server-key-picker-button'),
                        onPressed: (isSaving || serverState.isLoading)
                            ? null
                            : onPickKey,
                        child: const Text('Import'),
                      );
                      if (constraints.maxWidth <
                          AppWorkspaceBreakpoints.stackedActions) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            keyField,
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerRight,
                              child: importButton,
                            ),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: keyField),
                          const SizedBox(width: 10),
                          importButton,
                        ],
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (!serverState.isLoading &&
                (serverState.error?.trim().isNotEmpty ?? false))
              Text(
                onboardingConnectionErrorHeadline(
                  hostKeyMismatch: hostKeyMismatch,
                ),
                key: const Key('server-check-error-status'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: YaruColors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (localError case final message?
                when message != serverState.error) ...[
              const SizedBox(height: 12),
              _ErrorCard(message: message),
            ],
          ],
        ),
      ),
    );
  }
}

class _IntroScreen extends StatelessWidget {
  const _IntroScreen({required this.onStart, this.onRestoreRequest});

  final VoidCallback onStart;
  final VoidCallback? onRestoreRequest;

  @override
  Widget build(BuildContext context) {
    final steps = onboardingIntroSteps();
    final onRestoreRequest = this.onRestoreRequest;
    return Stack(
      children: [
        AppFocusedFlowScaffold(
          key: const Key('server-onboarding-intro-flow'),
          productName: 'Deploy Dash',
          title: 'Connect to your server',
          subtitle:
              'Deploy Dash will check the server, help you choose services, and finish setup safely.',
          icon: Icons.rocket_launch_outlined,
          maxWidth: 520,
          actions: [
            AppAccessibilityIdentifier(
              identifier: 'server-onboarding-start-button',
              child: FilledButton(
                key: const Key('server-onboarding-start-button'),
                autofocus: true,
                onPressed: onStart,
                child: const Text('Get started'),
              ),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < steps.length; index += 1)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: index == steps.length - 1 ? 0 : 8,
                  ),
                  child: Text('${index + 1}. ${steps[index]}'),
                ),
            ],
          ),
        ),
        if (onRestoreRequest != null)
          Positioned(
            left: 24,
            bottom: 24,
            child: RestoreLaunchButton(onPressed: onRestoreRequest),
          ),
      ],
    );
  }
}

/// Collects the database passphrase on the review screen.
///
/// Rendered inside the confirmation summary for pre-enrollment openings
/// only. Mirrors the old create screen's copy, keys, and accessibility
/// identifiers exactly, so existing automation addresses these fields
/// unchanged: only the host moved, from a screen swap to the Finish
/// screen itself. The two fields share one reveal toggle, also like the
/// old create screen.
/// The fresh-install password modal over the review step.
///
/// Owns the passphrase fields and the enrollment attempt: Finish setup
/// only opens it, and the modal hands the secret to [onSubmit]. Success
/// dismisses the modal and the enrollment host drives the wizard onward;
/// a refusal stays open with the failure next to the fields that caused
/// it. Enrolled installs never see this: their Finish saves directly.
class _EnrollmentDialog extends StatefulWidget {
  const _EnrollmentDialog({required this.onSubmit});

  final Future<EnrollmentResult> Function(String passphrase) onSubmit;

  @override
  State<_EnrollmentDialog> createState() => _EnrollmentDialogState();
}

class _EnrollmentDialogState extends State<_EnrollmentDialog> {
  final _passphraseController = TextEditingController();
  final _confirmPassphraseController = TextEditingController();
  final _passphraseFocusNode = FocusNode();
  final _confirmPassphraseFocusNode = FocusNode();
  bool _isSubmitting = false;
  String? _error;
  String? _failureDetails;

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmPassphraseController.dispose();
    _passphraseFocusNode.dispose();
    _confirmPassphraseFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submitEnrollment() async {
    final passphrase = _passphraseController.text.trim();
    final confirm = _confirmPassphraseController.text.trim();
    if (passphrase.isEmpty) {
      setState(() {
        _error = startupPassphraseEmptyMessage();
      });
      return;
    }
    if (passphrase != confirm) {
      setState(() {
        _error = startupPassphraseMismatchMessage();
      });
      return;
    }
    setState(() {
      _error = null;
      _failureDetails = null;
      _isSubmitting = true;
    });
    late final EnrollmentResult outcome;
    try {
      outcome = await widget.onSubmit(passphrase);
    } catch (error) {
      // An unexpected enrollment throw must not wedge the modal in its
      // submitting state with both buttons disabled: surface the same
      // create failure a refused enrollment shows, with the throw as
      // the technical details.
      if (!mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _error = startupCreateFailureMessage();
        _failureDetails = '$error';
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (outcome.enrolled) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _isSubmitting = false;
      _error = startupCreateFailureMessage();
      _failureDetails = outcome.failureDetails;
    });
  }

  /// Clears the failure on the next keystroke, like the unlock screen: a
  /// corrected value should not sit under a stale error.
  void _clearError() {
    if (_error == null && _failureDetails == null) {
      return;
    }
    setState(() {
      _error = null;
      _failureDetails = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppFormDialog(
      title: 'Create password and finish setup',
      description: startupDescription(isCreateMode: true, isRestoreMode: false),
      actions: [
        TextButton(
          key: const Key('enrollment-cancel-button'),
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        AppAccessibilityIdentifier(
          identifier: 'enrollment-submit-button',
          child: FilledButton(
            key: const Key('enrollment-submit-button'),
            onPressed: _isSubmitting ? null : _submitEnrollment,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isSubmitting) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                const Text('Create password'),
              ],
            ),
          ),
        ),
      ],
      child: _EnrollmentFields(
        passphraseController: _passphraseController,
        confirmPassphraseController: _confirmPassphraseController,
        passphraseFocusNode: _passphraseFocusNode,
        confirmPassphraseFocusNode: _confirmPassphraseFocusNode,
        isEnrolling: _isSubmitting,
        enrollmentError: _error,
        failureDetails: _failureDetails,
        onChanged: _clearError,
        onSubmit: _submitEnrollment,
      ),
    );
  }
}

class _EnrollmentFields extends StatefulWidget {
  const _EnrollmentFields({
    required this.passphraseController,
    required this.confirmPassphraseController,
    required this.passphraseFocusNode,
    required this.confirmPassphraseFocusNode,
    required this.isEnrolling,
    required this.enrollmentError,
    required this.failureDetails,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController passphraseController;
  final TextEditingController confirmPassphraseController;
  final FocusNode passphraseFocusNode;
  final FocusNode confirmPassphraseFocusNode;
  final bool isEnrolling;
  final String? enrollmentError;
  final String? failureDetails;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  @override
  State<_EnrollmentFields> createState() => _EnrollmentFieldsState();
}

class _EnrollmentFieldsState extends State<_EnrollmentFields> {
  bool _obscurePassphrase = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextFormField(
          fieldKey: const Key('database-passphrase-field'),
          controller: widget.passphraseController,
          labelText: 'Passphrase',
          obscureText: _obscurePassphrase,
          enabled: !widget.isEnrolling,
          focusNode: widget.passphraseFocusNode,
          autofocus: true,
          textInputAction: TextInputAction.next,
          onChanged: (_) => widget.onChanged(),
          onFieldSubmitted: (_) =>
              widget.confirmPassphraseFocusNode.requestFocus(),
          suffixIcon: IconButton(
            key: const Key('database-passphrase-visibility'),
            tooltip: _obscurePassphrase ? 'Show passphrase' : 'Hide passphrase',
            onPressed: () => setState(() {
              _obscurePassphrase = !_obscurePassphrase;
            }),
            icon: Icon(
              _obscurePassphrase ? Icons.visibility : Icons.visibility_off,
              semanticLabel: _obscurePassphrase
                  ? 'Show passphrase'
                  : 'Hide passphrase',
            ),
          ),
        ),
        const SizedBox(height: 12),
        AppTextFormField(
          fieldKey: const Key('database-confirm-passphrase-field'),
          controller: widget.confirmPassphraseController,
          labelText: 'Confirm passphrase',
          obscureText: _obscurePassphrase,
          enabled: !widget.isEnrolling,
          focusNode: widget.confirmPassphraseFocusNode,
          textInputAction: TextInputAction.done,
          onChanged: (_) => widget.onChanged(),
          onFieldSubmitted: (_) => widget.onSubmit(),
        ),
        if (widget.enrollmentError case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              key: const Key('database-passphrase-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (widget.failureDetails case final details?)
          AppTechnicalDetails(
            key: const Key('database-creation-failure-details'),
            child: SelectableText(details),
          ),
      ],
    );
  }
}

class _ReviewScreen extends StatelessWidget {
  const _ReviewScreen({
    required this.serverState,
    required this.latestResult,
    required this.isSaving,
    required this.localError,
    required this.onBack,
    required this.onSave,
  });

  final ServerState serverState;
  final Map<String, dynamic>? latestResult;
  final bool isSaving;
  final String? localError;
  final VoidCallback onBack;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final result =
        latestResult ?? serverState.result ?? const <String, dynamic>{};
    final setupActions = serverState.setupActions;
    final completedActionIds = _readIdSet(
      serverState.setupResult?['completed_action_ids'],
    );
    final scheduledActionIds = _readIdSet(
      serverState.setupResult?['scheduled_action_ids'],
    );
    final os = result['os']?.toString() ?? 'Unknown';
    final cpu = result['cpu']?.toString() ?? 'Unknown';
    final memory = result['memory_mb']?.toString() ?? 'Not reported';
    final disk = result['disk_gb']?.toString() ?? 'Not reported';
    final compatibility = _compatibilityFromResult(result);
    final compatibilityChecks = _compatibilityChecks(compatibility);
    final compatibilityPassed = _compatibilityPassed(compatibility);
    final compatibilitySummary = _compatibilitySummary(compatibility);
    final canSaveServer =
        compatibilityPassed && !isSaving && !serverState.isLoading;
    final busy = isSaving || serverState.isLoading;
    final tokens = context.appThemeTokens;

    return AppFocusedFlowScaffold(
      key: const Key('server-review-flow'),
      title: 'Review server details',
      subtitle:
          'Check what Deploy Dash found, then finish setup when everything looks right.',
      icon: Icons.fact_check_outlined,
      maxWidth: 520,
      actions: [
        OutlinedButton(
          key: const Key('server-confirmation-back-button'),
          onPressed: busy ? null : onBack,
          child: const Text('Back'),
        ),
        AppAccessibilityIdentifier(
          identifier: 'server-save-button',
          child: FilledButton(
            key: const Key('server-save-button'),
            autofocus: canSaveServer,
            onPressed: canSaveServer ? onSave : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(onboardingFinishButtonLabel(isSaving: busy)),
              ],
            ),
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SpecLine(label: 'Operating system', value: os),
          _SpecLine(label: 'CPU architecture', value: cpu),
          _SpecLine(label: 'Memory (MB)', value: memory),
          _SpecLine(label: 'Disk (GB)', value: disk),
          const SizedBox(height: 14),
          Text(
            onboardingCompatibilityHeading(),
            key: const Key('server-compatibility-title'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          AppAccessibilityIdentifier(
            identifier: 'server-compatibility-summary',
            child: Text(
              compatibilitySummary,
              key: const Key('server-compatibility-summary'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: compatibilityPassed
                    ? Colors.green.shade700
                    : YaruColors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          _SetupStatusPanel(
            busy: busy,
            compatibilityPassed: compatibilityPassed,
            compatibilityChecks: compatibilityChecks,
            compatibilitySummary: compatibilitySummary,
          ),
          SizedBox(height: tokens.spaceMd),
          _CompatibilityChecksExpansion(checks: compatibilityChecks),
          if (setupActions.isNotEmpty) ...[
            SizedBox(height: tokens.spaceMd),
            _SetupPlan(
              setupActions: setupActions,
              completedActionIds: completedActionIds,
              scheduledActionIds: scheduledActionIds,
            ),
          ],
          if (localError case final message?
              when message != serverState.error) ...[
            SizedBox(height: tokens.spaceMd),
            _ErrorCard(message: message),
          ],
        ],
      ),
    );
  }
}

class _SetupStatusPanel extends StatelessWidget {
  const _SetupStatusPanel({
    required this.busy,
    required this.compatibilityPassed,
    required this.compatibilityChecks,
    required this.compatibilitySummary,
  });

  final bool busy;
  final bool compatibilityPassed;
  final List<Map<String, dynamic>> compatibilityChecks;
  final String compatibilitySummary;

  @override
  Widget build(BuildContext context) {
    return AppPrimaryActionPanel(
      key: const Key('server-setup-action-row'),
      icon: compatibilityPassed
          ? Icons.check_circle_outline
          : Icons.error_outline,
      currentState: compatibilityPassed
          ? 'Ready to finish setup'
          : 'Setup is blocked',
      description: compatibilityPassed
          ? onboardingCompatibilityHint(
              compatibilityPassed: compatibilityPassed,
              summary: compatibilitySummary,
            )
          : 'Fix the blocking issue before continuing.',
      blockingReason: !busy && !compatibilityPassed
          ? _compatibilityBlockingReason(
              compatibilityChecks,
              fallback: onboardingFinishBlockedMessage(),
            )
          : null,
      blockingReasonKey: const Key('server-save-blocked-compatibility'),
      // Back and Finish live in the screen footer; the panel shows
      // status only.
      primaryAction: const SizedBox.shrink(),
    );
  }
}

class _CompatibilityChecksExpansion extends StatelessWidget {
  const _CompatibilityChecksExpansion({required this.checks});

  final List<Map<String, dynamic>> checks;

  @override
  Widget build(BuildContext context) {
    return AppTechnicalDetails(
      key: const Key('server-compatibility-checks-expansion'),
      title: 'Review compatibility checks',
      subtitle: '${checks.length} checks',
      child: _CompatibilityCheckList(checks: checks),
    );
  }
}

class _CompatibilityCheckList extends StatelessWidget {
  const _CompatibilityCheckList({required this.checks});

  final List<Map<String, dynamic>> checks;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('server-compatibility-check-list'),
      children: checks
          .map((check) {
            final passed = check['passed'] == true;
            final checkId = check['id']?.toString() ?? 'unknown';
            final label = check['label']?.toString() ?? checkId;
            final message = check['message']?.toString() ?? '';
            final actual = check['actual']?.toString().trim() ?? '';
            return Padding(
              key: Key('server-compatibility-check-$checkId'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      passed ? Icons.check_circle : Icons.cancel,
                      size: 18,
                      color: passed ? Colors.green.shade700 : YaruColors.red,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label),
                        if (message.isNotEmpty)
                          Text(
                            message,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (!passed && actual.isNotEmpty)
                          Text(
                            'Technical details: $actual',
                            key: Key(
                              'server-compatibility-check-$checkId-actual',
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          })
          .toList(growable: false),
    );
  }
}

class _SetupPlan extends StatelessWidget {
  const _SetupPlan({
    required this.setupActions,
    required this.completedActionIds,
    required this.scheduledActionIds,
  });

  final List<Map<String, dynamic>> setupActions;
  final Set<String> completedActionIds;
  final Set<String> scheduledActionIds;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final action in setupActions) {
      final part = action['part']?.toString() ?? 'other';
      if (!_setupPartLabels.containsKey(part)) {
        continue;
      }
      grouped.putIfAbsent(part, () => <Map<String, dynamic>>[]).add(action);
    }
    // Carry each part's label and actions alongside its id, so the loop below
    // reads them from a value it was handed rather than looking them up again
    // in two maps it has already established are populated.
    final orderedParts =
        <({String part, String label, List<Map<String, dynamic>> actions})>[];
    for (final entry in _setupPartLabels.entries) {
      final actions = grouped[entry.key];
      if (actions == null || actions.isEmpty) {
        continue;
      }
      orderedParts.add((part: entry.key, label: entry.value, actions: actions));
    }

    return AppTechnicalDetails(
      key: const Key('server-setup-plan-expansion'),
      title: 'Review setup plan',
      subtitle: '${setupActions.length} actions',
      child: Column(
        children: [
          for (final group in orderedParts)
            ExpansionTile(
              key: Key('setup-actions-${group.part}'),
              initiallyExpanded: false,
              tilePadding: EdgeInsets.zero,
              title: Text(group.label),
              subtitle: Text('${group.actions.length} actions'),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: group.actions
                  .map((action) {
                    final actionId = action['id']?.toString() ?? '';
                    final label = action['label']?.toString() ?? 'Action';
                    final description =
                        action['description']?.toString() ?? 'No description';
                    final isDone = completedActionIds.contains(actionId);
                    final wasScheduled = scheduledActionIds.contains(actionId);
                    final active = isDone || !wasScheduled;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: active,
                            onChanged: null,
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  description,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
        ],
      ),
    );
  }
}

/// The setup run's phase, shared by the progress content and the window
/// title so both agree on whether the run failed.
({bool isRunning, bool hasError}) _setupRunState({
  required bool isSaving,
  required ServerState serverState,
  required String? localError,
}) {
  final isRunning =
      isSaving ||
      (serverState.isLoading && serverState.taskType == ServerTaskType.setup);
  final serverError = serverState.error?.trim() ?? '';
  final hasError =
      !isRunning &&
      ((localError?.trim().isNotEmpty ?? false) || serverError.isNotEmpty);
  return (isRunning: isRunning, hasError: hasError);
}

class _SetupProgressStep extends StatelessWidget {
  const _SetupProgressStep({
    required this.serverState,
    required this.isSaving,
    required this.localError,
    required this.onRetry,
    required this.onBackToReview,
    this.showBackToReview = true,
  });

  final ServerState serverState;
  final bool isSaving;
  final String? localError;
  final VoidCallback onRetry;
  final VoidCallback onBackToReview;

  /// False in retry mode: the run starts at progress with no review step
  /// behind it, so "back" would land on an empty confirmation.
  final bool showBackToReview;

  @override
  Widget build(BuildContext context) {
    final (:isRunning, :hasError) = _setupRunState(
      isSaving: isSaving,
      serverState: serverState,
      localError: localError,
    );
    final failureSummary = onboardingSetupFailureSummary(
      error: localError ?? serverState.error,
      errorPayload: serverState.errorPayload,
      setupResult: serverState.setupResult,
    );
    final activityEvents = _recentSetupEvents(serverState);

    final progress = AppWorkspaceSection(
      key: const Key('server-setup-progress-card'),
      title: onboardingSetupProgressTitle(
        isRunning: isRunning,
        hasError: hasError,
      ),
      subtitle: onboardingSetupProgressDescription(
        isRunning: isRunning,
        hasError: hasError,
      ),
      icon: hasError ? Icons.error_outline : Icons.construction_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isRunning) ...[
            const LinearProgressIndicator(key: Key('server-setup-progress')),
            const SizedBox(height: 12),
            Text(
              'Current setup is running.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _TelemetryNoticeCard(),
            const SizedBox(height: 12),
          ],
          if (hasError) ...[
            AppAccessibilityIdentifier(
              identifier: 'server-setup-failure-message',
              child: _InlineErrorMessage(
                key: const Key('server-setup-failure-message'),
                message: failureSummary,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ExpansionTile(
              key: const Key('server-setup-current-activity'),
              initiallyExpanded: true,
              title: const Text('Current setup activity'),
              subtitle: Text(
                activityEvents.isEmpty
                    ? 'No messages yet'
                    : '${activityEvents.length} recent messages',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [
                if (activityEvents.isEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No current setup messages yet.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  for (final entry in activityEvents)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SelectableText(
                          _setupEventMessage(entry),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
              ],
            ),
          ),
          if (hasError) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('server-setup-retry-button'),
                  onPressed: onRetry,
                  child: const Text('Retry setup'),
                ),
                if (showBackToReview)
                  OutlinedButton(
                    key: const Key('server-setup-back-to-review-button'),
                    onPressed: onBackToReview,
                    child: const Text('Back to review'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    return AppAccessibilityIdentifier(
      identifier: 'server-setup-progress-card',
      child: progress,
    );
  }
}

/// The passive setup-progress telemetry notice: usage reporting is on by
/// default, and the switch beside it flips the live service flag at once.
/// No dialog, no focus steal, no animation -- setup keeps running
/// underneath, and reaching completion stamps the notice as shown.
class _TelemetryNoticeCard extends ConsumerWidget {
  const _TelemetryNoticeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      telemetrySettingsProvider.select((settings) => settings.enabled),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SwitchListTile(
        key: const Key('server-setup-telemetry-switch'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        value: enabled,
        title: Text(telemetryHelpImproveTitle()),
        subtitle: Text(telemetryNoticeCardDescription()),
        onChanged: (value) => unawaited(
          ref.read(telemetrySettingsProvider.notifier).setEnabled(value),
        ),
      ),
    );
  }
}

class _ServicesStep extends StatefulWidget {
  const _ServicesStep({required this.isFinishing, required this.onComplete});

  final bool isFinishing;
  final Future<void> Function({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  })
  onComplete;

  @override
  State<_ServicesStep> createState() => _ServicesStepState();
}

class _ServicesStepState extends State<_ServicesStep> {
  bool _enableEmailAccounts = false;
  bool _enableDomains = false;
  bool _enableDatabases = false;
  String _selectedPostgresVersion =
      ServerPostgresConfig.defaults.postgresVersion;
  final Set<String> _selectedPostgresExtensions = <String>{};

  bool get _hasSelectedServices =>
      _enableEmailAccounts || _enableDomains || _enableDatabases;

  void _complete() {
    widget.onComplete(
      enableEmailAccounts: _enableEmailAccounts,
      enableDomains: _enableDomains,
      enableDatabases: _enableDatabases,
      postgresVersion: _selectedPostgresVersion,
      postgresExtensions: _selectedPostgresExtensions.toList()
        ..sort((left, right) => left.compareTo(right)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFinishing = widget.isFinishing;
    final actionLabel = _hasSelectedServices
        ? 'Install and continue'
        : 'Continue';
    final busyLabel = _hasSelectedServices
        ? 'Installing and continuing...'
        : 'Continuing...';

    return AppWorkspaceSection(
      title: 'Choose services',
      subtitle:
          'Turn on the tools you want this server to host. You can change these later.',
      icon: Icons.widgets_outlined,
      primaryActionPanel: AppPrimaryActionPanel(
        currentState: _hasSelectedServices
            ? 'Ready to install selected services'
            : 'Ready to continue without extra services',
        description: _hasSelectedServices
            ? 'Deploy Dash will install the selected services during setup.'
            : 'You can enable services later from Server Management.',
        primaryAction: AppAccessibilityIdentifier(
          identifier: 'services-selection-continue-button',
          child: FilledButton(
            key: const Key('services-selection-continue-button'),
            autofocus: true,
            onPressed: isFinishing ? null : _complete,
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (isFinishing)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                Text(
                  isFinishing ? busyLabel : actionLabel,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppToggleField(
            key: const Key('service-toggle-email'),
            title: 'Email accounts',
            subtitle: !_emailAndDomainsBackendAvailable
                ? 'Coming soon'
                : 'Create and manage inboxes on this server.',
            value: _enableEmailAccounts,
            onChanged: _emailAndDomainsBackendAvailable
                ? (value) {
                    setState(() => _enableEmailAccounts = value);
                  }
                : null,
          ),
          AppToggleField(
            key: const Key('service-toggle-domains'),
            title: 'Domains',
            subtitle: !_emailAndDomainsBackendAvailable
                ? 'Coming soon'
                : 'Manage website and email domain names here.',
            value: _enableDomains,
            onChanged: _emailAndDomainsBackendAvailable
                ? (value) {
                    setState(() => _enableDomains = value);
                  }
                : null,
          ),
          AppToggleField(
            key: const Key('service-toggle-databases'),
            title: 'PostgreSQL database',
            subtitle: 'Host app databases and managed database users.',
            value: _enableDatabases,
            onChanged: (value) {
              setState(() => _enableDatabases = value);
            },
          ),
          if (_enableDatabases) ...[
            const SizedBox(height: 8),
            AppSelectFormField<String>(
              key: const Key('service-postgres-version-dropdown'),
              value: _selectedPostgresVersion,
              labelText: 'PostgreSQL version',
              helperText: 'Choose one version to install on this server.',
              items: const <String>['16', '17', '18']
                  .map(
                    (version) => DropdownMenuItem<String>(
                      value: version,
                      child: Text('Postgres $version'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() {
                  _selectedPostgresVersion = value;
                });
              },
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              key: const Key('service-postgres-advanced-options'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
              title: const Text('Advanced options'),
              subtitle: const Text('Extensions'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Only selected extensions are installed into the managed '
                    'database image.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Selecting vector, pg_search, or postgis may take longer on '
                    'first setup while Deploy Dash builds the extension image.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final extension
                    in ServerPostgresConfig.requestedExtensions)
                  CheckboxListTile.adaptive(
                    key: Key('service-postgres-extension-$extension'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value:
                        ServerPostgresConfig.supportedExtensions.contains(
                          extension,
                        ) &&
                        _selectedPostgresExtensions.contains(extension),
                    onChanged:
                        ServerPostgresConfig.supportedExtensions.contains(
                          extension,
                        )
                        ? (value) {
                            setState(() {
                              if (value ?? false) {
                                _selectedPostgresExtensions.add(extension);
                              } else {
                                _selectedPostgresExtensions.remove(extension);
                              }
                            });
                          }
                        : null,
                    title: Text(_postgresExtensionTitle(extension)),
                    subtitle:
                        ServerPostgresConfig.unsupportedExtensions.contains(
                          extension,
                        )
                        ? const Text(
                            'Not packaged in the current Postgres image.',
                          )
                        : null,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SpecLine extends StatelessWidget {
  const _SpecLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    // The bottom padding stays at this call site: it spaces spec lines, not
    // rows in general, so it is not part of the shared row owner.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppLabeledValueRow(
        label: label,
        value: value,
        width: 170,
        labelStyle: Theme.of(context).textTheme.bodySmall,
        crossAxisAlignment: CrossAxisAlignment.center,
        valueSelectable: true,
        gap: 0,
      ),
    );
  }
}

class _InlineErrorMessage extends StatelessWidget {
  const _InlineErrorMessage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: YaruColors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.error_outline, color: YaruColors.red, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(message)),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: YaruColors.red.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.error_outline, color: YaruColors.red, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(message)),
          ],
        ),
      ),
    );
  }
}

const _emailAndDomainsBackendAvailable = false;

const Map<String, String> _setupPartLabels = <String, String>{
  'part1': 'System foundation and access control',
  'part2': 'Stability and resource management',
  'part3': 'Docker infrastructure preparation',
  'part4': 'Passive security and monitoring',
  'part5': 'Production build infrastructure',
};

String? _validateRequired(String? value, String fieldName) {
  if (value == null || value.trim().isEmpty) {
    return '$fieldName is required';
  }
  return null;
}

String? _validateHost(String? value) {
  return validateHostOrAddress(value);
}

String? _validateServerDisplayName(String? value) {
  final requiredError = _validateRequired(value, 'Server name');
  if (requiredError != null) {
    return requiredError;
  }
  // `_validateRequired` above returned null, so `value` is non-null and
  // non-blank; `?? ''` states that without asserting it.
  final serverName = (value ?? '').trim();
  if (serverName.length > 80) {
    return 'Use 80 characters or fewer.';
  }
  if (RegExp(r'[\r\n\t]').hasMatch(serverName)) {
    return 'Use a single-line name.';
  }
  return null;
}

String? _validatePort(String? value) {
  final requiredError = _validateRequired(value, 'SSH port');
  if (requiredError != null) {
    return requiredError;
  }
  // Non-null for the same reason as in `_validateServerDisplayName`.
  final parsed = int.tryParse((value ?? '').trim());
  if (parsed == null || parsed < 1 || parsed > 65535) {
    return 'Port must be between 1 and 65535';
  }
  return null;
}

String _postgresExtensionTitle(String extension) {
  return switch (extension) {
    'vector' => 'pgvector',
    _ => extension,
  };
}

Map<String, dynamic> _compatibilityFromResult(Map<String, dynamic> result) {
  final raw = result['compatibility'];
  if (raw is Map) {
    final normalized = mapFrom(raw);
    final status = normalized['status']?.toString().toLowerCase();
    if (status == 'pass' || status == 'fail') {
      return normalized;
    }
  }
  return <String, dynamic>{
    'status': 'fail',
    'summary':
        'Deploy Dash could not review this server yet. Check the connection and try again.',
    'checks': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'compatibility_unavailable',
        'label': 'Deploy Dash could review the server',
        'category': 'probe',
        'passed': false,
        'expected':
            'A compatibility report is returned by the server/check '
            'workflow operation.',
        'actual': 'No compatibility report found in server response.',
        'message':
            'Deploy Dash could not verify compatibility requirements for '
            'this server.',
      },
    ],
  };
}

List<Map<String, dynamic>> _compatibilityChecks(
  Map<String, dynamic> compatibility,
) {
  final raw = compatibility['checks'];
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }

  final parsed = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) {
      continue;
    }
    final check = mapFrom(item);
    final id = check['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      continue;
    }
    parsed.add(<String, dynamic>{
      'id': id,
      'label': check['label']?.toString() ?? id,
      'passed': check['passed'] == true,
      'expected': check['expected']?.toString() ?? '',
      'actual': check['actual']?.toString() ?? '',
      'message': check['message']?.toString() ?? '',
    });
  }
  return parsed;
}

bool _compatibilityPassed(Map<String, dynamic> compatibility) {
  return compatibility['status']?.toString().toLowerCase() == 'pass';
}

String _compatibilitySummary(Map<String, dynamic> compatibility) {
  final summary = compatibility['summary']?.toString().trim() ?? '';
  return onboardingCompatibilityHint(
    compatibilityPassed: _compatibilityPassed(compatibility),
    summary: summary,
  );
}

String _compatibilityBlockingReason(
  List<Map<String, dynamic>> compatibilityChecks, {
  required String fallback,
}) {
  for (final check in compatibilityChecks) {
    if (check['passed'] == true) {
      continue;
    }
    final message = check['message']?.toString().trim() ?? '';
    if (message.isNotEmpty) {
      return message;
    }
  }
  return fallback;
}

List<Map<String, dynamic>> _recentSetupEvents(ServerState serverState) {
  final currentEvents = serverState.taskType == ServerTaskType.setup
      ? serverState.events
      : const <Map<String, dynamic>>[];
  final displayable = currentEvents
      .where((event) {
        return _setupEventMessage(event).trim().isNotEmpty;
      })
      .toList(growable: false);
  if (displayable.length <= 8) {
    return displayable;
  }
  return displayable.sublist(displayable.length - 8);
}

String _setupEventMessage(Map<String, dynamic> event) {
  final message = event['message']?.toString().trim() ?? '';
  if (message.isNotEmpty) {
    return message;
  }
  return event['type']?.toString().trim() ?? '';
}

Set<String> _readIdSet(dynamic value) {
  if (value is! List) {
    return const <String>{};
  }
  final ids = <String>{};
  for (final entry in value) {
    final id = entry?.toString().trim() ?? '';
    if (id.isNotEmpty) {
      ids.add(id);
    }
  }
  return ids;
}
