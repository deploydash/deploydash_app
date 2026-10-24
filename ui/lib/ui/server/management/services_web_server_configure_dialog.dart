part of '../server_management_view.dart';

Future<ServerWebServerConfig?> _showWebServerConfigureDialog({
  required BuildContext context,
  required String serviceId,
  required ServerWebServerConfig initialConfig,
}) async {
  var enableHttpsRedirect = initialConfig.enableHttpsRedirect;
  var enableCompression = initialConfig.enableCompression;
  var enableAccessLogs = initialConfig.enableAccessLogs;
  var enableCloudflarePlugin = initialConfig.enableDnsPluginCloudflare;
  var enablePorkbunPlugin = initialConfig.enableDnsPluginPorkbun;
  var enableNamecheapPlugin = initialConfig.enableDnsPluginNamecheap;
  var enableCloudnsPlugin = initialConfig.enableDnsPluginCloudns;
  var enableEasydnsPlugin = initialConfig.enableDnsPluginEasydns;
  return showDialog<ServerWebServerConfig>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFormDialog(
            key: Key('service-config-dialog-$serviceId'),
            title: 'Web server settings',
            description:
                'Choose the defaults Deploy Dash uses when it publishes web apps on this server.',
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(
                    ServerWebServerConfig(
                      enableHttpsRedirect: enableHttpsRedirect,
                      enableCompression: enableCompression,
                      enableAccessLogs: enableAccessLogs,
                      enableDnsPluginCloudflare: enableCloudflarePlugin,
                      enableDnsPluginPorkbun: enablePorkbunPlugin,
                      enableDnsPluginNamecheap: enableNamecheapPlugin,
                      enableDnsPluginCloudns: enableCloudnsPlugin,
                      enableDnsPluginEasydns: enableEasydnsPlugin,
                    ),
                  );
                },
                child: const Text('Save'),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppFormSection(
                  description:
                      'Ports 80 and 443 are always managed automatically.',
                  children: [],
                ),
                AppToggleField(
                  value: enableHttpsRedirect,
                  onChanged: (value) {
                    setDialogState(() => enableHttpsRedirect = value);
                  },
                  title: 'Always use HTTPS',
                  subtitle: 'Send visitors to the secure version of the site.',
                ),
                AppToggleField(
                  value: enableCompression,
                  onChanged: (value) {
                    setDialogState(() => enableCompression = value);
                  },
                  title: 'Response compression',
                  subtitle: 'Reduce page size for faster loads.',
                ),
                AppToggleField(
                  value: enableAccessLogs,
                  onChanged: (value) {
                    setDialogState(() => enableAccessLogs = value);
                  },
                  title: 'Access logs',
                  subtitle: 'Store request logs for troubleshooting.',
                ),
                const SizedBox(height: 8),
                AppFormSection(
                  title: 'DNS providers',
                  description:
                      'Turn on only the providers you plan to use for DNS-based certificates.',
                  children: [
                    AppToggleField(
                      value: enableCloudflarePlugin,
                      onChanged: (value) {
                        setDialogState(() => enableCloudflarePlugin = value);
                      },
                      title: 'Cloudflare',
                    ),
                    AppToggleField(
                      value: enablePorkbunPlugin,
                      onChanged: (value) {
                        setDialogState(() => enablePorkbunPlugin = value);
                      },
                      title: 'Porkbun',
                    ),
                    AppToggleField(
                      value: enableNamecheapPlugin,
                      onChanged: (value) {
                        setDialogState(() => enableNamecheapPlugin = value);
                      },
                      title: 'Namecheap',
                    ),
                    AppToggleField(
                      value: enableCloudnsPlugin,
                      onChanged: (value) {
                        setDialogState(() => enableCloudnsPlugin = value);
                      },
                      title: 'ClouDNS',
                    ),
                    AppToggleField(
                      value: enableEasydnsPlugin,
                      onChanged: (value) {
                        setDialogState(() => enableEasydnsPlugin = value);
                      },
                      title: 'EasyDNS',
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
