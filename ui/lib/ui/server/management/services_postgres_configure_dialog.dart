part of '../server_management_view.dart';

Future<ServerPostgresConfig?> _showPostgresConfigureDialog({
  required BuildContext context,
  required ServerPostgresConfig initialConfig,
  required String title,
  required String saveButtonLabel,
  required bool lockVersion,
  String? upgradeBlockedReason,
}) async {
  var selectedVersion = initialConfig.postgresVersion;
  final selectedExtensions = initialConfig.enabledExtensions
      .where(ServerPostgresConfig.supportedExtensions.contains)
      .toSet();
  // Hoisted so the `== null` checks promote it; a parameter is never
  // promoted inside the dialog callbacks below.
  final blockedUpgradeReason = upgradeBlockedReason;
  return showDialog<ServerPostgresConfig>(
    context: context,
    builder: (dialogContext) {
      final upgradeButton = TextButton(
        key: const Key('postgres-upgrade-major-button'),
        onPressed: blockedUpgradeReason == null
            ? () async {
                final navigator = Navigator.of(dialogContext);
                final target = await _showPostgresUpgradeDialog(
                  context: dialogContext,
                  currentVersion: initialConfig.postgresVersion,
                );
                if (target == null) {
                  return;
                }
                navigator.pop(
                  ServerPostgresConfig(
                    postgresVersion: target,
                    superuserPassword: initialConfig.superuserPassword,
                    enabledExtensions: selectedExtensions.toList()
                      ..sort((left, right) => left.compareTo(right)),
                  ),
                );
              }
            : null,
        child: Text(postgresUpgradeButton()),
      );
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFormDialog(
            key: const Key('service-config-dialog-database'),
            title: title,
            description:
                'Choose the PostgreSQL version and the extensions Deploy Dash should keep ready for your projects.',
            maxWidth: 540,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(
                    ServerPostgresConfig(
                      postgresVersion: selectedVersion,
                      superuserPassword: initialConfig.superuserPassword,
                      enabledExtensions: selectedExtensions.toList()
                        ..sort((left, right) => left.compareTo(right)),
                    ),
                  );
                },
                child: Text(saveButtonLabel),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lockVersion) ...[
                  Text(
                    postgresUpgradeFixedVersionLabel(
                      initialConfig.postgresVersion,
                    ),
                    key: const Key('postgres-version-fixed'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    postgresUpgradeFixedVersionHint(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: blockedUpgradeReason == null
                        ? upgradeButton
                        : Tooltip(
                            message: blockedUpgradeReason,
                            child: upgradeButton,
                          ),
                  ),
                ] else ...[
                  AppSelectFormField<String>(
                    key: const Key('postgres-version-dropdown'),
                    value: selectedVersion,
                    labelText: 'PostgreSQL version',
                    helperText: 'PostgreSQL 17 is the recommended default.',
                    items: const [
                      DropdownMenuItem(value: '16', child: Text('16')),
                      DropdownMenuItem(
                        value: '17',
                        child: Text('17 (recommended default)'),
                      ),
                      DropdownMenuItem(value: '18', child: Text('18')),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setDialogState(() => selectedVersion = value);
                    },
                  ),
                ],
                const SizedBox(height: 12),
                ExpansionTile(
                  key: const Key('postgres-advanced-options'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                  title: const Text('Advanced options'),
                  subtitle: const Text('Extensions'),
                  children: [
                    AppFormSection(
                      title: 'Extensions',
                      description:
                          'Deploy Dash enables these for existing project databases and new ones. Some extensions may take longer the first time while the image is prepared.',
                      children: [
                        for (final option in _postgresExtensionOptions)
                          AppCheckboxField(
                            dense: true,
                            value: option.supported
                                ? selectedExtensions.contains(option.key)
                                : false,
                            onChanged: option.supported
                                ? (value) {
                                    setDialogState(() {
                                      if (value ?? false) {
                                        selectedExtensions.add(option.key);
                                      } else {
                                        selectedExtensions.remove(option.key);
                                      }
                                    });
                                  }
                                : null,
                            title: option.title,
                            subtitle: option.supported
                                ? null
                                : (option.supportHint ??
                                      'Not currently supported'),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
