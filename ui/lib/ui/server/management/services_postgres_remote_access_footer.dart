part of '../server_management_view.dart';

enum _PostgresRemoteAccessScope { currentDevice, specific, anywhere }

/// Converts the detected SSH peer into the narrowest possible client network.
String? _postgresRemoteAccessHostCidr(String? rawAddress) {
  final address = InternetAddress.tryParse(rawAddress?.trim() ?? '');
  if (address == null) {
    return null;
  }
  final prefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
  return '${address.address}/$prefix';
}

/// Splits the operator's explicit CIDR list without duplicating entries.
List<String> _postgresRemoteAccessSpecificCidrs(String raw) {
  final values = raw
      .split(RegExp(r'[,\s]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty);
  return values.toSet().toList(growable: false);
}

/// Collects the source allowlist before any firewall mutation can start.
Future<List<String>?> _showPostgresRemoteAccessDialog(
  BuildContext context, {
  required String? detectedAddress,
}) async {
  final detectedCidr = _postgresRemoteAccessHostCidr(detectedAddress);
  var scope = detectedCidr == null
      ? _PostgresRemoteAccessScope.specific
      : _PostgresRemoteAccessScope.currentDevice;
  var specificText = '';
  return showDialog<List<String>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        final specificCidrs = _postgresRemoteAccessSpecificCidrs(specificText);
        final canConfirm = switch (scope) {
          _PostgresRemoteAccessScope.currentDevice => detectedCidr != null,
          _PostgresRemoteAccessScope.specific => specificCidrs.isNotEmpty,
          _PostgresRemoteAccessScope.anywhere => true,
        };
        return AppDialogScaffold(
          key: const Key('postgres-remote-access-dialog'),
          title: 'Choose who can connect',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('postgres-remote-access-confirm'),
              onPressed: !canConfirm
                  ? null
                  : () {
                      final sourceCidrs = switch (scope) {
                        _PostgresRemoteAccessScope.currentDevice => [
                          detectedCidr!,
                        ],
                        _PostgresRemoteAccessScope.specific => specificCidrs,
                        _PostgresRemoteAccessScope.anywhere => <String>[],
                      };
                      Navigator.of(dialogContext).pop(sourceCidrs);
                    },
              child: const Text('Open for 1 hour'),
            ),
          ],
          child: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PostgreSQL will require TLS. Limit port 5432 to the '
                  'smallest source range that needs it.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                ChoiceChip(
                  key: const Key('postgres-remote-access-current-device'),
                  selected: scope == _PostgresRemoteAccessScope.currentDevice,
                  onSelected: detectedCidr == null
                      ? null
                      : (_) => setDialogState(
                          () =>
                              scope = _PostgresRemoteAccessScope.currentDevice,
                        ),
                  label: Text(
                    detectedCidr == null
                        ? 'This device (address unavailable)'
                        : 'This device ($detectedCidr)',
                  ),
                ),
                const SizedBox(height: 8),
                ChoiceChip(
                  key: const Key('postgres-remote-access-specific'),
                  selected: scope == _PostgresRemoteAccessScope.specific,
                  onSelected: (_) => setDialogState(
                    () => scope = _PostgresRemoteAccessScope.specific,
                  ),
                  label: const Text('Specific IPs or networks'),
                ),
                if (scope == _PostgresRemoteAccessScope.specific) ...[
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('postgres-remote-access-specific-cidrs'),
                    onChanged: (value) =>
                        setDialogState(() => specificText = value),
                    decoration: const InputDecoration(
                      labelText: 'Source CIDRs',
                      hintText: '198.51.100.24/32, 2001:db8::24/128',
                      helperText: 'Separate addresses or networks with commas.',
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ChoiceChip(
                  key: const Key('postgres-remote-access-anywhere'),
                  selected: scope == _PostgresRemoteAccessScope.anywhere,
                  onSelected: (_) => setDialogState(
                    () => scope = _PostgresRemoteAccessScope.anywhere,
                  ),
                  label: const Text('Anywhere (not recommended)'),
                ),
                if (scope == _PostgresRemoteAccessScope.anywhere) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Warning: this permits every internet address to try '
                    'signing in for the full one-hour window.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _PostgresRemoteAccessFooter extends StatelessWidget {
  const _PostgresRemoteAccessFooter({
    required this.service,
    required this.stagedState,
    required this.allowsPostgres,
    required this.sourceCidrs,
    required this.detectedAddress,
    required this.tlsEnabled,
    required this.tlsCaFingerprint,
    required this.tlsCaCertificate,
    required this.serverHost,
    required this.isRefreshing,
    required this.isMutating,
    required this.error,
    required this.onOpen,
    required this.onClose,
    required this.onRefresh,
    required this.formatDateTime,
  });

  final _ServerServiceRecord service;
  final _FirewallStagedState? stagedState;
  final bool allowsPostgres;
  final List<String> sourceCidrs;
  final String? detectedAddress;
  final bool tlsEnabled;
  final String? tlsCaFingerprint;
  final String? tlsCaCertificate;
  final String serverHost;
  final bool isRefreshing;
  final bool isMutating;
  final String? error;
  final ValueChanged<List<String>> onOpen;
  final VoidCallback onClose;
  final VoidCallback onRefresh;
  final String Function(DateTime value) formatDateTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Hoisted so the `!= null` check promotes it; a widget field is never
    // promoted.
    final error = this.error;
    final remoteAccessOpen = stagedState != null && allowsPostgres;
    final remoteAccessExpiry = stagedState?.expiresAt;
    final unrelatedStagedChange = stagedState != null && !allowsPostgres;
    final buttonsBusy = service.isBusy || isRefreshing || isMutating;
    final canOpen =
        !buttonsBusy &&
        !remoteAccessOpen &&
        !unrelatedStagedChange &&
        service.status.isReady &&
        tlsEnabled;
    String? openBlockedReason;
    if (buttonsBusy) {
      openBlockedReason =
          'Please wait for the current service action to finish.';
    } else if (unrelatedStagedChange) {
      openBlockedReason =
          'Another staged firewall change is pending. Commit or rollback it in '
          'the Firewall tab first.';
    } else if (!service.status.isReady) {
      openBlockedReason =
          'Start the database service before opening remote access.';
    } else if (!tlsEnabled) {
      openBlockedReason =
          'Configure the database service once to enable TLS before opening '
          'remote access.';
    }

    final openButton = FilledButton.icon(
      key: const Key('service-enable-postgres-remote-access'),
      onPressed: canOpen
          ? () async {
              final sourceCidrs = await _showPostgresRemoteAccessDialog(
                context,
                detectedAddress: detectedAddress,
              );
              if (sourceCidrs != null) {
                onOpen(sourceCidrs);
              }
            }
          : null,
      icon: isMutating && !remoteAccessOpen
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.public),
      label: Text(servicesTemporaryDatabaseAccessOpenButton()),
    );

    return Container(
      key: const Key('service-footer-database-remote-access'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: remoteAccessOpen
            ? Colors.orange.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border.all(
          color: remoteAccessOpen
              ? Colors.orange.withValues(alpha: 0.35)
              : theme.dividerColor.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            servicesTemporaryDatabaseAccessTitle(),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            servicesTemporaryDatabaseAccessSubtitle(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (remoteAccessOpen)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.public, color: Colors.orange, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        servicesTemporaryDatabaseAccessOpenMessage(),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (remoteAccessExpiry != null)
                        Text(
                          'Closes automatically at '
                          '${formatDateTime(remoteAccessExpiry)}.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        sourceCidrs.isEmpty
                            ? 'Allowed source: Anywhere'
                            : 'Allowed source: ${sourceCidrs.join(', ')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text('TLS required (sslmode=verify-ca)'),
                      if (tlsCaFingerprint != null &&
                          tlsCaFingerprint!.trim().isNotEmpty)
                        Text(
                          'CA SHA-256: $tlsCaFingerprint',
                          key: const Key('service-postgres-tls-ca-fingerprint'),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            )
          else if (unrelatedStagedChange)
            Text(
              servicesTemporaryDatabaseAccessBlockedByFirewallChange(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Text(
              servicesTemporaryDatabaseAccessClosedHint(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (error != null && error.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              error,
              key: const Key('service-postgres-remote-access-error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canOpen ||
                  openBlockedReason == null ||
                  openBlockedReason.trim().isEmpty)
                openButton
              else
                Tooltip(message: openBlockedReason, child: openButton),
              OutlinedButton.icon(
                key: const Key('service-close-postgres-remote-access'),
                onPressed: !isMutating && remoteAccessOpen ? onClose : null,
                icon: isMutating && remoteAccessOpen
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_outline),
                label: Text(servicesTemporaryDatabaseAccessCloseButton()),
              ),
              if (remoteAccessOpen &&
                  tlsCaCertificate != null &&
                  tlsCaCertificate!.trim().isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('service-copy-postgres-ca-certificate'),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: tlsCaCertificate!),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy CA certificate'),
                ),
              if (remoteAccessOpen)
                OutlinedButton.icon(
                  key: const Key('service-copy-postgres-tls-template'),
                  onPressed: () async {
                    final host = formatHostForDisplay(serverHost);
                    await Clipboard.setData(
                      ClipboardData(
                        text:
                            'postgresql://USER:PASSWORD@$host:5432/DATABASE'
                            '?sslmode=verify-ca&sslrootcert=/path/to/'
                            'deploydash-postgres-ca.crt',
                      ),
                    );
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Copy TLS connection template'),
                ),
              IconButton(
                key: const Key('service-refresh-postgres-remote-access'),
                tooltip: servicesTemporaryDatabaseAccessRefreshButton(),
                onPressed: isRefreshing ? null : onRefresh,
                icon: isRefreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
