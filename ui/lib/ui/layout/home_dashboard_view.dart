import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import '../../domain/server.dart';
import '../../providers/project_deletion_provider.dart';
import '../../providers/project_provider.dart';
import '../system/app_copy.dart';
import '../system/app_dialogs.dart';
import '../system/app_sections.dart';
import '../system/app_state_views.dart';
import '../system/app_window_title.dart';
import '../system/app_workspace.dart';
import 'home_telemetry_nag_card.dart';

/// Number of servers before the master pane offers a filter field.
const int homeServerFilterThreshold = 6;

/// Number of projects before the detail pane offers a filter field.
const int homeProjectFilterThreshold = 8;

class DeletedProjectNotice {
  const DeletedProjectNotice({
    required this.projectName,
    required this.warnings,
    this.completed = true,
  });

  final String projectName;
  final List<String> warnings;
  final bool completed;
}

class HomeDashboardView extends StatelessWidget {
  const HomeDashboardView({
    super.key,
    required this.projects,
    required this.selectedServer,
    required this.serverCount,
    required this.deletedProjectNotice,
    this.servers = const <Server>[],
    this.projectDeletionRecoveries = const [],
    this.pendingSetupServerIds = const {},
    required this.onDismissDeletedProjectNotice,
    this.onRetryProjectCleanup,
    this.onRemovePendingProjectLocalRecord,
    this.onSelectServer,
    this.onRetryServerSetup,
    required this.onOpenProject,
    required this.onCreateProject,
    required this.onAddServer,
    required this.onOpenServerManagement,
    this.telemetryNagVisible = false,
    this.onShareTelemetryNag,
    this.onDismissTelemetryNag,
  });

  /// Projects belonging to [selectedServer].
  final List<Project> projects;

  /// Every saved server, used for the directory master pane.
  final List<Server> servers;

  final Server? selectedServer;
  final int serverCount;
  final DeletedProjectNotice? deletedProjectNotice;
  final List<ProjectDeletionRecoveryRecord> projectDeletionRecoveries;
  final VoidCallback onDismissDeletedProjectNotice;
  final Future<void> Function(ProjectDeletionRecoveryRecord recovery)?
  onRetryProjectCleanup;
  final Future<void> Function(ProjectDeletionRecoveryRecord recovery)?
  onRemovePendingProjectLocalRecord;
  final ValueChanged<String>? onSelectServer;

  /// Ids of servers saved before provisioning finished. Those rows carry a
  /// warning badge, and the detail pane offers to finish their setup.
  final Set<String> pendingSetupServerIds;

  /// Retries setup for an incomplete server. Null when the caller offers
  /// no retry entry from Home.
  final ValueChanged<String>? onRetryServerSetup;
  final ValueChanged<String> onOpenProject;
  final VoidCallback onCreateProject;
  final VoidCallback onAddServer;
  final VoidCallback onOpenServerManagement;

  /// Whether the once-ever telemetry nag renders above the directory.
  /// State lives with the caller; this view only renders it.
  final bool telemetryNagVisible;

  /// Switches reporting back on. Null while the nag is hidden.
  final VoidCallback? onShareTelemetryNag;

  /// Records the nag as shown without switching on. Null while hidden.
  final VoidCallback? onDismissTelemetryNag;

  @override
  Widget build(BuildContext context) {
    // Hoisted so the `!= null` check below promotes it; a widget field cannot
    // be promoted, and this one is read nine times inside the card.
    final deletedNotice = deletedProjectNotice;
    // Same hoist: promotion for the pending checks on the selected server.
    final selected = selectedServer;
    final shareTelemetryNag = onShareTelemetryNag;
    final dismissTelemetryNag = onDismissTelemetryNag;
    return AppWindowTitle(
      screen: selectedServer == null
          ? 'Home - No server yet'
          : 'Home - Server selected',
      child: ListView(
        key: const Key('home-dashboard-scroll'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (telemetryNagVisible &&
              shareTelemetryNag != null &&
              dismissTelemetryNag != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: HomeTelemetryNagCard(
                onShare: shareTelemetryNag,
                onDismiss: dismissTelemetryNag,
              ),
            ),
          if (deletedNotice != null)
            _HomeCard(
              key: const Key('home-delete-notice-card'),
              icon: YaruIcons.information,
              title: !deletedNotice.completed
                  ? 'Project cleanup needs attention'
                  : deletedNotice.warnings.isEmpty
                  ? 'Project deleted'
                  : 'Project deleted with follow-up items',
              subtitle: !deletedNotice.completed
                  ? '"${deletedNotice.projectName}" is hidden from normal use until cleanup succeeds.'
                  : deletedNotice.warnings.isEmpty
                  ? '"${deletedNotice.projectName}" was removed.'
                  : '"${deletedNotice.projectName}" was removed, but '
                        'some remote cleanup steps still need attention.',
              action: TextButton(
                key: const Key('home-delete-notice-dismiss-button'),
                onPressed: onDismissDeletedProjectNotice,
                child: const Text('Dismiss'),
              ),
              child: deletedNotice.warnings.isEmpty
                  ? const Text(
                      'You are back on the Home screen. Open another project '
                      'when you are ready.',
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Remote cleanup warnings:'),
                        const SizedBox(height: 8),
                        for (final warning in deletedNotice.warnings)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '- $warning',
                              key: Key(
                                'home-delete-warning-${warning.hashCode}',
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          for (final recovery in projectDeletionRecoveries)
            _ProjectCleanupCard(
              key: Key('home-project-cleanup-${recovery.projectId}'),
              recovery: recovery,
              onRetry: onRetryProjectCleanup,
              onRemoveLocalRecord: onRemovePendingProjectLocalRecord,
            ),
          Wrap(
            key: const Key('home-overview-panel'),
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                key: const Key('home-add-server-button'),
                autofocus: selectedServer == null,
                onPressed: onAddServer,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Add server'),
              ),
              FilledButton.icon(
                key: const Key('home-new-project-button'),
                onPressed:
                    selected == null ||
                        pendingSetupServerIds.contains(selected.id)
                    ? null
                    : onCreateProject,
                icon: const Icon(YaruIcons.folder_new),
                label: const Text('New project'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          AppMasterDetail(
            master: _HomeServerList(
              key: const Key('home-servers-card'),
              servers: servers,
              serverCount: serverCount,
              selectedServerId: selectedServer?.id,
              projectCountsByServerId: _projectCountsByServerId(),
              pendingSetupServerIds: pendingSetupServerIds,
              onSelectServer: onSelectServer,
              onOpenServerManagement: onOpenServerManagement,
              onAddServer: onAddServer,
            ),
            detail: _HomeProjectList(
              key: const Key('home-projects-card'),
              projects: projects,
              selectedServer: selectedServer,
              hasServers: serverCount > 0,
              isSelectedServerSetupPending:
                  selected != null &&
                  pendingSetupServerIds.contains(selected.id),
              onOpenProject: onOpenProject,
              onRetryServerSetup: onRetryServerSetup,
            ),
          ),
        ],
      ),
    );
  }

  Map<String, int> _projectCountsByServerId() {
    final counts = <String, int>{};
    for (final project in projects) {
      final serverId = project.serverId;
      if (serverId == null) {
        continue;
      }
      counts[serverId] = (counts[serverId] ?? 0) + 1;
    }
    return counts;
  }
}

class _HomeServerList extends StatefulWidget {
  const _HomeServerList({
    super.key,
    required this.servers,
    required this.serverCount,
    required this.selectedServerId,
    required this.projectCountsByServerId,
    required this.pendingSetupServerIds,
    required this.onSelectServer,
    required this.onOpenServerManagement,
    required this.onAddServer,
  });

  final List<Server> servers;
  final int serverCount;
  final String? selectedServerId;
  final Map<String, int> projectCountsByServerId;
  final Set<String> pendingSetupServerIds;
  final ValueChanged<String>? onSelectServer;
  final VoidCallback onOpenServerManagement;
  final VoidCallback onAddServer;

  @override
  State<_HomeServerList> createState() => _HomeServerListState();
}

class _HomeServerListState extends State<_HomeServerList> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? widget.servers
        : widget.servers
              .where(
                (server) =>
                    server.name.toLowerCase().contains(needle) ||
                    server.host.toLowerCase().contains(needle),
              )
              .toList(growable: false);
    return AppWorkspaceSection(
      icon: YaruIcons.computer,
      title: 'Servers',
      subtitle:
          '${widget.serverCount} ${widget.serverCount == 1 ? 'server' : 'servers'} saved on this computer.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.servers.length >= homeServerFilterThreshold) ...[
            TextField(
              key: const Key('home-server-filter-field'),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Filter servers',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (value) => setState(() => _filter = value),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.servers.isEmpty)
            const AppEmptyStateView(
              icon: YaruIcons.server,
              title: 'No servers yet',
              message:
                  'Connect a server so Deploy Dash can create and deploy '
                  'projects on it.',
            )
          else if (visible.isEmpty)
            const AppEmptyStateView(
              key: Key('home-servers-filter-empty'),
              icon: YaruIcons.server,
              title: 'No servers match that filter',
              message: 'Clear the filter to see every saved server.',
            )
          else
            for (var index = 0; index < visible.length; index++) ...[
              if (index > 0) const Divider(height: 1),
              _HomeServerRow(
                server: visible[index],
                selected: visible[index].id == widget.selectedServerId,
                setupPending: widget.pendingSetupServerIds.contains(
                  visible[index].id,
                ),
                projectCount:
                    widget.projectCountsByServerId[visible[index].id] ?? 0,
                showProjectCount: visible[index].id == widget.selectedServerId,
                onSelect: widget.onSelectServer,
                onOpenServerManagement: widget.onOpenServerManagement,
              ),
            ],
        ],
      ),
    );
  }
}

class _HomeServerRow extends StatelessWidget {
  const _HomeServerRow({
    required this.server,
    required this.selected,
    required this.setupPending,
    required this.projectCount,
    required this.showProjectCount,
    required this.onSelect,
    required this.onOpenServerManagement,
  });

  final Server server;
  final bool selected;
  final bool setupPending;
  final int projectCount;

  /// Project counts are only known for the selected server's project list.
  final bool showProjectCount;

  final ValueChanged<String>? onSelect;
  final VoidCallback onOpenServerManagement;

  @override
  Widget build(BuildContext context) {
    final selectServer = onSelect;
    final osName = server.osName?.trim();
    final subtitleParts = <String>[
      server.host,
      if (osName != null && osName.isNotEmpty) osName,
    ];
    return AppResourceRow(
      key: Key('home-server-${server.id}'),
      leading: const Icon(YaruIcons.server),
      title: server.name,
      subtitle: subtitleParts.join(' - '),
      selected: selected,
      onTap: selectServer == null
          ? (selected ? onOpenServerManagement : null)
          : () => selectServer(server.id),
      status: Wrap(
        spacing: 6,
        runSpacing: 4,
        alignment: WrapAlignment.end,
        children: [
          if (setupPending)
            const AppStatusBadge(
              label: 'Setup incomplete',
              tone: AppStatusTone.warning,
            ),
          if (showProjectCount)
            AppStatusBadge(
              label:
                  '$projectCount ${projectCount == 1 ? 'project' : 'projects'}',
            ),
          for (final badge in _serviceBadges(server))
            AppStatusBadge(label: badge, tone: AppStatusTone.info),
        ],
      ),
      actions: [
        IconButton(
          key: Key('home-server-manage-${server.id}'),
          tooltip: 'Manage server',
          icon: const Icon(Icons.tune, semanticLabel: 'Manage server'),
          onPressed: () {
            onSelect?.call(server.id);
            onOpenServerManagement();
          },
        ),
      ],
    );
  }

  static List<String> _serviceBadges(Server server) {
    return <String>[
      if (server.serviceDatabaseEnabled) 'Databases',
      if (server.serviceEmailEnabled) 'Email',
      if (server.serviceDomainEnabled) 'Domains',
    ];
  }
}

class _HomeProjectList extends StatefulWidget {
  const _HomeProjectList({
    super.key,
    required this.projects,
    required this.selectedServer,
    required this.hasServers,
    required this.isSelectedServerSetupPending,
    required this.onOpenProject,
    required this.onRetryServerSetup,
  });

  final List<Project> projects;
  final Server? selectedServer;
  final bool hasServers;
  final bool isSelectedServerSetupPending;
  final ValueChanged<String> onOpenProject;
  final ValueChanged<String>? onRetryServerSetup;

  @override
  State<_HomeProjectList> createState() => _HomeProjectListState();
}

class _HomeProjectListState extends State<_HomeProjectList> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final server = widget.selectedServer;
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? widget.projects
        : widget.projects
              .where(
                (project) =>
                    project.name.toLowerCase().contains(needle) ||
                    project.primaryDomain.toLowerCase().contains(needle),
              )
              .toList(growable: false);
    return AppDetailPane(
      title: server == null ? 'Projects' : 'Projects on ${server.name}',
      subtitle: server == null
          ? 'Choose a server to see its projects.'
          : 'Open a project to deploy it, review logs, or manage its services.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.projects.length >= homeProjectFilterThreshold) ...[
            TextField(
              key: const Key('home-project-filter-field'),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Filter projects',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (value) => setState(() => _filter = value),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.projects.isEmpty)
            if (widget.isSelectedServerSetupPending && server != null)
              _ResumeSetupEmptyState(
                server: server,
                onRetryServerSetup: widget.onRetryServerSetup,
              )
            else
              AppEmptyStateView(
                key: server == null && widget.hasServers
                    ? const Key('home-projects-no-server-chosen')
                    : null,
                icon: YaruIcons.folder,
                title: server != null
                    ? 'No projects yet'
                    : widget.hasServers
                    ? 'Select a server'
                    : 'Connect a server first',
                message: server != null
                    ? 'Create a project to configure a web app, workers, '
                          'backups, and supporting services.'
                    : widget.hasServers
                    ? 'Choose a server above to see the projects on it.'
                    : 'Add a server before creating a project.',
              )
          else if (visible.isEmpty)
            const AppEmptyStateView(
              key: Key('home-projects-filter-empty'),
              icon: YaruIcons.folder,
              title: 'No projects match that filter',
              message: 'Clear the filter to see every project on this server.',
            )
          else
            for (var index = 0; index < visible.length; index++) ...[
              if (index > 0) const Divider(height: 1),
              _HomeProjectRow(
                project: visible[index],
                onOpenProject: widget.onOpenProject,
              ),
            ],
        ],
      ),
    );
  }
}

/// Detail-pane state for a selected server whose setup never finished.
///
/// A pending server cannot hold projects, so the pane resumes setup
/// instead of inviting project creation. The retry callback is the same
/// entry the Server Management incomplete card offers.
class _ResumeSetupEmptyState extends StatelessWidget {
  const _ResumeSetupEmptyState({
    required this.server,
    required this.onRetryServerSetup,
  });

  final Server server;
  final ValueChanged<String>? onRetryServerSetup;

  @override
  Widget build(BuildContext context) {
    final retry = onRetryServerSetup;
    return AppEmptyStateView(
      key: const Key('home-projects-resume-setup'),
      icon: YaruIcons.server,
      title: 'Finish setting up ${server.name}',
      message:
          'Setup did not complete on this server. Retry to continue where '
          'it left off.',
      action: retry == null
          ? null
          : FilledButton(
              key: const Key('home-projects-resume-setup-button'),
              onPressed: () => retry(server.id),
              child: const Text('Finish setup'),
            ),
    );
  }
}

class _HomeProjectRow extends StatelessWidget {
  const _HomeProjectRow({required this.project, required this.onOpenProject});

  final Project project;
  final ValueChanged<String> onOpenProject;

  @override
  Widget build(BuildContext context) {
    final domain = project.primaryDomain.trim();
    final subtitleParts = <String>[
      displayProjectTypeLabel(project.type),
      if (domain.isNotEmpty) domain,
    ];
    return AppResourceRow(
      key: Key('home-project-${project.id}'),
      leading: const Icon(YaruIcons.folder),
      title: project.name,
      subtitle: subtitleParts.join(' - '),
      status: project.lastDeployedAt == null
          ? const AppStatusBadge(
              label: 'Not deployed yet',
              tone: AppStatusTone.neutral,
            )
          : Text(
              'Deployed ${formatRelativeTimestamp(project.lastDeployedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
      actions: const [Icon(Icons.chevron_right)],
      onTap: () => onOpenProject(project.id),
    );
  }
}

String displayProjectTypeLabel(String type) {
  final normalized = type.trim().toLowerCase();
  if (normalized == 'app' || normalized == 'web app') {
    return 'Web app';
  }
  return type.trim().isEmpty ? 'Project' : type.trim();
}

class _ProjectCleanupCard extends StatefulWidget {
  const _ProjectCleanupCard({
    super.key,
    required this.recovery,
    required this.onRetry,
    required this.onRemoveLocalRecord,
  });

  final ProjectDeletionRecoveryRecord recovery;
  final Future<void> Function(ProjectDeletionRecoveryRecord recovery)? onRetry;
  final Future<void> Function(ProjectDeletionRecoveryRecord recovery)?
  onRemoveLocalRecord;

  @override
  State<_ProjectCleanupCard> createState() => _ProjectCleanupCardState();
}

class _ProjectCleanupCardState extends State<_ProjectCleanupCard> {
  bool _busy = false;
  String? _error;

  Future<void> _run(
    Future<void> Function(ProjectDeletionRecoveryRecord recovery)? action,
  ) async {
    if (_busy || action == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(widget.recovery);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Cleanup could not continue: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _confirmRemoveLocalRecord() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDestructiveConfirmDialog(
        key: const Key('home-project-cleanup-forget-dialog'),
        title: 'Remove local project record?',
        description:
            'Deploy Dash will stop tracking this project even though remote '
            'resources may remain on the server. Use this only when the '
            'server cannot be recovered.',
        confirmLabel: 'Remove local record',
        confirmButtonKey: const Key(
          'home-project-cleanup-forget-confirm-button',
        ),
      ),
    );
    if (confirmed == true) {
      await _run(widget.onRemoveLocalRecord);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final failedSteps = widget.recovery.steps
        .where((step) => step.status == ProjectDeletionStepStatus.failed)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _HomeCard(
        icon: Icons.warning_amber_rounded,
        title: 'Cleanup required for ${widget.recovery.projectName}',
        subtitle:
            'The project is preserved locally but disabled until its server resources are removed.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (failedSteps.isNotEmpty) ...[
              for (final step in failedSteps.take(4))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${step.label}: ${step.message ?? 'cleanup did not finish'}',
                    key: Key(
                      'home-project-cleanup-step-${widget.recovery.projectId}-${step.id}',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            if (error != null) ...[
              Text(
                error,
                key: Key(
                  'home-project-cleanup-error-${widget.recovery.projectId}',
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: Key(
                    'home-project-cleanup-retry-${widget.recovery.projectId}',
                  ),
                  onPressed: _busy || widget.onRetry == null
                      ? null
                      : () => _run(widget.onRetry),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_busy ? 'Retrying...' : 'Retry cleanup'),
                ),
                OutlinedButton(
                  key: Key(
                    'home-project-cleanup-forget-${widget.recovery.projectId}',
                  ),
                  onPressed: _busy || widget.onRemoveLocalRecord == null
                      ? null
                      : _confirmRemoveLocalRecord,
                  child: const Text('Remove local record'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      icon: icon,
      title: title,
      subtitle: subtitle,
      headerAction: action,
      child: child,
    );
  }
}
