import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';

import '../../models/run_guard.dart';
import '../../models/result.dart';
import '../../models/postgres_storage_status.dart';
import '../../models/server_scope.dart';
import '../../providers/project_workspace_data_provider.dart';
import '../../providers/backup_provider.dart';
import '../../providers/server_list_provider.dart';
import '../../providers/server_provider.dart';
import '../../services/app_analytics_service.dart';
import '../../services/concurrency_engine.dart';
import '../../services/ssh_service.dart';
import '../../services/postgres_service_password.dart';
import '../../services/project_database_settings.dart';
import '../../utils/format_clock_time.dart';
import '../../utils/host_format.dart';
import '../../utils/payload_codecs.dart';
import '../../utils/terminal_output_filter.dart';
import '../../utils/trim_or_null.dart';
import '../system/app_dialogs.dart';
import '../system/app_context_navigation.dart';
import '../system/app_forms.dart';
import '../system/app_sections.dart';
import '../system/app_theme.dart';
import '../system/app_window_title.dart';
import '../system/app_workspace.dart';
import '../system/container_runtime_status.dart';
import '../system/operation_state_presentation.dart';
import '../navigation/desktop_route.dart';
import 'management/firewall_tab_logic.dart';
import 'management/overview_tab_logic.dart';
import 'management/updates_tab_logic.dart';
import 'management/server_docker_storage_logic.dart';
import 'management/system_ssh_key_import.dart';
import 'management/system_ssh_key_replacement_logic.dart';
import 'management/server_system_settings_logic.dart';
import 'management/services_tab_logic.dart';

part 'management/shared_models.dart';
part 'management/server_scope_mixin.dart';
part 'management/overview_tab.dart';
part 'management/services_tab.dart';
part 'management/services_tab_activity.dart';
part 'management/services_tab_operations.dart';
part 'management/services_tab_status_operations.dart';
part 'management/services_tab_actions.dart';
part 'management/services_delete_dialog.dart';
part 'management/services_postgres_configure_dialog.dart';
part 'management/services_web_server_configure_dialog.dart';
part 'management/services_postgres_remote_access_footer.dart';
part 'management/services_postgres_storage_footer.dart';
part 'management/services_postgres_storage_migrate_dialog.dart';
part 'management/services_postgres_upgrade_dialog.dart';
part 'management/updates_tab.dart';
part 'management/firewall_tab.dart';
part 'management/system_tab.dart';
part 'management/docker_storage_section.dart';
part 'management/panel_widgets.dart';

typedef ServerSshKeyPicker = Future<XFile?> Function();
typedef ServerSshKeyImporter =
    Future<ImportedSshKeyFile> Function(String filePath);

class ServerManagementView extends StatefulWidget {
  const ServerManagementView({
    super.key,
    this.server,
    this.initialTabIndex = 0,
    this.isSetupPending = false,
    this.onDestinationSelected,
    this.onTerminalLine,
    this.onRemoveServer,
    this.onRetrySetup,
    this.pickSshKeyFile,
    this.importSshKeyFile,
  });

  final Server? server;
  final int initialTabIndex;

  /// Renders the incomplete card instead of the tabbed view. An
  /// early-saved server has no services to manage yet, so retry and
  /// remove are its only actions.
  final bool isSetupPending;
  final ValueChanged<int>? onDestinationSelected;
  final ServerTerminalLineWriter? onTerminalLine;
  final Future<void> Function()? onRemoveServer;
  final VoidCallback? onRetrySetup;
  final ServerSshKeyPicker? pickSshKeyFile;
  final ServerSshKeyImporter? importSshKeyFile;

  @override
  State<ServerManagementView> createState() => _ServerManagementViewState();
}

class _ServerManagementViewState extends State<ServerManagementView> {
  static final _destinations = <AppContextNavigationItem>[
    AppContextNavigationItem(
      id: DesktopServerManagementTab.overview.id,
      label: 'Overview',
      icon: Icons.dashboard_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopServerManagementTab.services.id,
      label: 'Services',
      icon: Icons.dns_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopServerManagementTab.updates.id,
      label: 'Updates',
      icon: Icons.system_update_alt_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopServerManagementTab.security.id,
      label: 'Security',
      icon: Icons.security_outlined,
    ),
    AppContextNavigationItem(
      id: DesktopServerManagementTab.settings.id,
      label: 'Settings',
      icon: Icons.settings_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    if (widget.isSetupPending && server != null) {
      return _SetupIncompleteCard(
        server: server,
        onRetrySetup: widget.onRetrySetup,
        onRemoveServer: widget.onRemoveServer,
      );
    }
    return DefaultTabController(
      key: ValueKey(widget.initialTabIndex),
      length: _destinations.length,
      initialIndex: widget.initialTabIndex.clamp(0, _destinations.length - 1),
      child: Builder(
        builder: (tabContext) {
          final controller = DefaultTabController.of(tabContext);
          final content = TabBarView(
            children: [
              _OverviewTab(widget.server),
              _ServicesTab(
                widget.server,
                onTerminalLine: widget.onTerminalLine,
              ),
              _UpdatesTab(widget.server, onTerminalLine: widget.onTerminalLine),
              _FirewallTab(
                widget.server,
                onTerminalLine: widget.onTerminalLine,
              ),
              _SystemTab(
                widget.server,
                onTerminalLine: widget.onTerminalLine,
                onRemoveServer: widget.onRemoveServer,
                pickSshKeyFile: widget.pickSshKeyFile,
                importSshKeyFile: widget.importSshKeyFile,
              ),
            ],
          );
          return AnimatedBuilder(
            animation: controller,
            // `content` is built once above and closed over, which reuses the
            // same subtree exactly as the `child:` argument would -- without
            // the nullable parameter that argument forces on the builder.
            builder: (context, _) => AppWindowTitle(
              screen:
                  'Server management - ${_destinations[controller.index].label}',
              child: AppWorkspaceScaffold(
                destinations: _destinations,
                selectedIndex: controller.index,
                onSelected: (index) {
                  controller.animateTo(index);
                  widget.onDestinationSelected?.call(index);
                },
                navigationKeyNamespace: 'server-management',
                child: content,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Server Management for a server whose setup never finished.
///
/// An early-saved server has no services, updates, firewall, or system
/// state to manage, so the tabbed view is replaced by this card: retry
/// setup from the saved bootstrap credential, or remove the server. The
/// remove confirm mirrors the System tab copy.
class _SetupIncompleteCard extends StatefulWidget {
  const _SetupIncompleteCard({
    required this.server,
    required this.onRetrySetup,
    required this.onRemoveServer,
  });

  final Server server;
  final VoidCallback? onRetrySetup;
  final Future<void> Function()? onRemoveServer;

  @override
  State<_SetupIncompleteCard> createState() => _SetupIncompleteCardState();
}

class _SetupIncompleteCardState extends State<_SetupIncompleteCard> {
  var _isRemovingServer = false;

  Future<void> _confirmAndRemoveServer() async {
    final handler = widget.onRemoveServer;
    if (handler == null || _isRemovingServer) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const AppDestructiveConfirmDialog(
        title: 'Remove this server?',
        description:
            'This removes the saved server from Deploy Dash so you can '
            'reconnect it from scratch. It does not erase anything on the '
            'server itself.',
        confirmLabel: 'Remove server',
        confirmButtonKey: Key('setup-incomplete-remove-confirm-button'),
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }
    setState(() => _isRemovingServer = true);
    try {
      await handler();
    } finally {
      if (mounted) {
        setState(() => _isRemovingServer = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppWorkspaceSection(
      icon: YaruIcons.server,
      title: 'Finish setting up ${widget.server.name}',
      subtitle:
          'Setup did not complete on ${widget.server.host}. Retry to '
          'continue where it left off, or remove the server and start over.',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton(
            key: const Key('server-management-retry-setup-button'),
            onPressed: widget.onRetrySetup,
            child: const Text('Retry setup'),
          ),
          OutlinedButton(
            key: const Key('server-management-remove-server-button'),
            onPressed: _isRemovingServer ? null : _confirmAndRemoveServer,
            child: _isRemovingServer
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Remove server'),
          ),
        ],
      ),
    );
  }
}
