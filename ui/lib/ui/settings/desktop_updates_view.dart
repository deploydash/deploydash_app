import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/desktop_update_service.dart';
import '../../utils/trim_or_null.dart';
import '../system/app_accessibility_identifier.dart';
import '../system/app_dialogs.dart';
import '../system/app_sections.dart';
import '../system/app_workspace.dart';

class DesktopUpdatesView extends ConsumerWidget {
  const DesktopUpdatesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(desktopUpdateControllerProvider);
    return updateState.when(
      loading: () => const AppWorkspaceSection(
        key: Key('app-settings-updates-section'),
        title: 'Desktop updates',
        subtitle: 'Checking this installation.',
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => AppWorkspaceSection(
        key: const Key('app-settings-updates-section'),
        title: 'Desktop updates',
        subtitle: 'Update status is temporarily unavailable.',
        child: _UpdateFailure(
          message: 'Deploy Dash could not read this installation version.',
          onRetry: () => unawaited(
            ref.read(desktopUpdateControllerProvider.notifier).check(),
          ),
        ),
      ),
      data: (snapshot) => _UpdateContent(snapshot: snapshot),
    );
  }
}

class _UpdateContent extends ConsumerWidget {
  const _UpdateContent({required this.snapshot});

  final DesktopUpdateSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final release = snapshot.release;
    // Hoisted so the checks promote them; a public final field is never
    // promoted.
    final message = trimOrNull(snapshot.message);
    final checkedAt = snapshot.checkedAt;
    final status = _presentation(snapshot);
    return AppWorkspaceSection(
      key: const Key('app-settings-updates-section'),
      title: 'Desktop updates',
      subtitle: status.subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAccessibilityIdentifier(
            identifier: 'app-settings-update-status',
            child: AppStatusBadge(
              key: const Key('app-settings-update-status'),
              label: status.label,
              tone: status.tone,
              icon: status.icon,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Installed version: ${snapshot.currentBuild.displayVersion}',
            key: const Key('app-settings-installed-version'),
            style: theme.textTheme.bodyMedium,
          ),
          if (release != null) ...[
            const SizedBox(height: 6),
            Text(
              'Available version: ${release.version}+${release.build}',
              key: const Key('app-settings-available-version'),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (release != null && snapshot.hasUpdate) ...[
            const SizedBox(height: 12),
            Text(
              release.title,
              key: const Key('app-settings-update-title'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              release.summary,
              key: const Key('app-settings-update-summary'),
            ),
            if (release.severity == DesktopUpdateSeverity.security ||
                release.severity == DesktopUpdateSeverity.critical) ...[
              const SizedBox(height: 10),
              Text(
                release.severity == DesktopUpdateSeverity.critical
                    ? 'This is a critical update. You can keep using Deploy Dash, '
                          'but updating promptly is strongly recommended.'
                    : 'This update contains security improvements. You can keep '
                          'using Deploy Dash while you choose when to install it.',
                key: const Key('app-settings-update-security-warning'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              _installGuidance(release.installStrategy),
              key: const Key('app-settings-update-install-guidance'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(
              message,
              key: const Key('app-settings-update-message'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (checkedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Last checked: ${checkedAt.toLocal()}',
              key: const Key('app-settings-update-checked-at'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (snapshot.hasUpdate && release != null)
                FilledButton.icon(
                  key: const Key('app-settings-update-now-button'),
                  onPressed: () => unawaited(_startUpdate(context, ref)),
                  icon: const Icon(Icons.system_update_alt_outlined),
                  label: const Text('Update now'),
                )
              else
                AppAccessibilityIdentifier(
                  identifier: 'app-settings-check-updates-button',
                  child: FilledButton.icon(
                    key: const Key('app-settings-check-updates-button'),
                    onPressed: () => unawaited(
                      ref
                          .read(desktopUpdateControllerProvider.notifier)
                          .check(),
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check for updates'),
                  ),
                ),
              if (release != null)
                OutlinedButton.icon(
                  key: const Key('app-settings-release-notes-button'),
                  onPressed: () => unawaited(_openReleaseNotes(context, ref)),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Release notes'),
                ),
              if (snapshot.status == DesktopUpdateStatus.updateAvailable &&
                  release != null &&
                  snapshot.dismissedReleaseId != release.releaseId)
                TextButton(
                  key: const Key('app-settings-dismiss-update-button'),
                  onPressed: () => unawaited(
                    ref
                        .read(desktopUpdateControllerProvider.notifier)
                        .dismiss(),
                  ),
                  child: const Text('Remind me later'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _startUpdate(BuildContext context, WidgetRef ref) async {
    final launched = await ref
        .read(desktopUpdateControllerProvider.notifier)
        .startUpdate();
    if (!context.mounted || launched) {
      return;
    }
    await _showLaunchFailure(
      context,
      'Deploy Dash could not open the system update service. Try again or '
      'install the update from the same source you originally used.',
    );
  }

  Future<void> _openReleaseNotes(BuildContext context, WidgetRef ref) async {
    final launched = await ref
        .read(desktopUpdateControllerProvider.notifier)
        .openReleaseNotes();
    if (!context.mounted || launched) {
      return;
    }
    await _showLaunchFailure(
      context,
      'Deploy Dash could not open the release notes.',
    );
  }
}

class _UpdateFailure extends StatelessWidget {
  const _UpdateFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, key: const Key('app-settings-update-load-error')),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('app-settings-update-retry-button'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    );
  }
}

class _UpdatePresentation {
  const _UpdatePresentation({
    required this.label,
    required this.subtitle,
    required this.tone,
    required this.icon,
  });

  final String label;
  final String subtitle;
  final AppStatusTone tone;
  final IconData icon;
}

_UpdatePresentation _presentation(DesktopUpdateSnapshot snapshot) {
  return switch (snapshot.status) {
    DesktopUpdateStatus.notChecked => const _UpdatePresentation(
      label: 'Not checked yet',
      subtitle: 'Check whether a newer stable release is available.',
      tone: AppStatusTone.neutral,
      icon: Icons.info_outline,
    ),
    DesktopUpdateStatus.current => const _UpdatePresentation(
      label: 'Up to date',
      subtitle: 'This installation is on the latest stable release.',
      tone: AppStatusTone.positive,
      icon: Icons.check_circle_outline,
    ),
    DesktopUpdateStatus.updateAvailable => const _UpdatePresentation(
      label: 'Update available',
      subtitle: 'A newer stable release is ready to install.',
      tone: AppStatusTone.warning,
      icon: Icons.system_update_alt_outlined,
    ),
    DesktopUpdateStatus.updateRequired => const _UpdatePresentation(
      label: 'Important update available',
      subtitle: 'This version is no longer supported, but remains usable.',
      tone: AppStatusTone.negative,
      icon: Icons.warning_amber_outlined,
    ),
    DesktopUpdateStatus.unsupported => const _UpdatePresentation(
      label: 'Installation unsupported',
      subtitle: 'Install a supported Deploy Dash package to receive updates.',
      tone: AppStatusTone.negative,
      icon: Icons.error_outline,
    ),
    DesktopUpdateStatus.deferred => const _UpdatePresentation(
      label: 'Up to date',
      subtitle: 'The next release is being rolled out gradually.',
      tone: AppStatusTone.positive,
      icon: Icons.schedule_outlined,
    ),
    DesktopUpdateStatus.failed => const _UpdatePresentation(
      label: 'Could not check',
      subtitle: 'Your app remains available. Try the update check again later.',
      tone: AppStatusTone.warning,
      icon: Icons.cloud_off_outlined,
    ),
  };
}

String _installGuidance(DesktopUpdateInstallStrategy strategy) {
  return switch (strategy) {
    DesktopUpdateInstallStrategy.aptRepository =>
      'Ubuntu will open its package manager and may ask you to approve the '
          'update. Deploy Dash never enters your administrator password.',
    DesktopUpdateInstallStrategy.snap =>
      'The Snap Store manages this installation and will apply the update.',
    DesktopUpdateInstallStrategy.flatpak =>
      'Your Flatpak software manager will apply the update.',
    DesktopUpdateInstallStrategy.sparkle =>
      'The signed and notarized Deploy Dash updater will guide the install.',
    DesktopUpdateInstallStrategy.macAppStore =>
      'The Mac App Store manages this installation.',
    DesktopUpdateInstallStrategy.windowsStore =>
      'Microsoft Store manages this installation.',
  };
}

// D-43 (T-013): left hand-built — description+shrink rendering differs from
// showAppNotice's child:Text.
Future<void> _showLaunchFailure(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AppDialogScaffold(
      title: 'Could not open update',
      description: message,
      actions: [
        FilledButton(
          key: const Key('app-settings-update-error-ok-button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
      child: const SizedBox.shrink(),
    ),
  );
}
