part of '../../project_workspace.dart';

String? _normalizedDeploymentSettingsAppSubdirectory(String value) {
  final normalized = value
      .trim()
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'^/+|/+$'), '');
  if (normalized.isEmpty) {
    return null;
  }
  final segments = normalized.split('/');
  final cleaned = <String>[];
  for (final segment in segments) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      return _invalidAppSubdirectory;
    }
    cleaned.add(trimmed);
  }
  if (cleaned.isEmpty) {
    return null;
  }
  return cleaned.join('/');
}

bool _isValidDeploymentSettingsDomain(String value) {
  final candidate = value.trim().toLowerCase();
  if (candidate.isEmpty || candidate == 'not configured') {
    return false;
  }
  final fqdn = RegExp(
    r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
  );
  return fqdn.hasMatch(candidate);
}

bool _isValidDeploymentSettingsBranch(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty) {
    return false;
  }
  return RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(candidate);
}

bool _isValidDeploymentPublicHealthPath(String value) {
  final normalized = value.trim();
  return normalized.startsWith('/') &&
      normalized.length <= 512 &&
      !normalized.contains('#') &&
      !normalized.contains(RegExp(r'[\x00-\x1f\x7f]'));
}

class AppDeploymentSettingsDialogResult {
  const AppDeploymentSettingsDialogResult({
    required this.repositoryFullName,
    required this.primaryDomain,
    required this.domainRoutingMode,
    required this.canonicalDomain,
    required this.deployBranch,
    required this.appPort,
    required this.railpackProvider,
    required this.railpackBuildCommand,
    required this.railpackRunCommand,
    required this.appSubdirectory,
    required this.tlsChallengeMode,
    required this.tlsDnsProvider,
    required this.tlsDnsCredentials,
    required this.publicHealthCheckEnabled,
    required this.publicHealthCheckPath,
  });

  final String repositoryFullName;
  final String primaryDomain;
  final String domainRoutingMode;
  final String canonicalDomain;
  final String deployBranch;
  final int appPort;
  final String? railpackProvider;
  final String railpackBuildCommand;
  final String railpackRunCommand;
  final String? appSubdirectory;
  final String tlsChallengeMode;
  final String? tlsDnsProvider;
  final Map<String, String> tlsDnsCredentials;
  final bool publicHealthCheckEnabled;
  final String publicHealthCheckPath;
}

class AppDeploymentSettingsDialog extends StatefulWidget {
  const AppDeploymentSettingsDialog({
    super.key,
    required this.repositories,
    required this.initialRepository,
    required this.initialPrimaryDomain,
    required this.initialDomainRoutingMode,
    required this.initialBranch,
    required this.initialPortText,
    required this.initialRuntimeSelectionId,
    required this.initialBuildCommand,
    required this.initialRunCommand,
    required this.initialAppSubdirectory,
    required this.availableDnsProviderSpecs,
    required this.initialTlsChallengeMode,
    required this.initialDnsProvider,
    required this.initialDnsCredentials,
    this.initialPublicHealthCheckEnabled = true,
    this.initialPublicHealthCheckPath = '/',
  });

  final List<GitHubRepository> repositories;
  final String? initialRepository;
  final String initialPrimaryDomain;
  final String initialDomainRoutingMode;
  final String initialBranch;
  final String initialPortText;
  final String initialRuntimeSelectionId;
  final String initialBuildCommand;
  final String initialRunCommand;
  final String initialAppSubdirectory;
  final List<AppDeploymentDnsProviderSpec> availableDnsProviderSpecs;
  final AppDeploymentTlsChallengeMode initialTlsChallengeMode;
  final String? initialDnsProvider;
  final Map<String, String> initialDnsCredentials;
  final bool initialPublicHealthCheckEnabled;
  final String initialPublicHealthCheckPath;

  @override
  State<AppDeploymentSettingsDialog> createState() =>
      _AppDeploymentSettingsDialogState();
}

class _AppDeploymentSettingsDialogState
    extends State<AppDeploymentSettingsDialog> {
  late final TextEditingController _domainController = TextEditingController(
    text: widget.initialPrimaryDomain,
  );
  late final TextEditingController _branchController = TextEditingController(
    text: widget.initialBranch,
  );
  late final TextEditingController _portController = TextEditingController(
    text: widget.initialPortText,
  );
  late final TextEditingController _buildCommandController =
      TextEditingController(text: widget.initialBuildCommand);
  late final TextEditingController _runCommandController =
      TextEditingController(text: widget.initialRunCommand);
  late final TextEditingController _appSubdirectoryController =
      TextEditingController(text: widget.initialAppSubdirectory);
  late final TextEditingController _publicHealthPathController =
      TextEditingController(text: widget.initialPublicHealthCheckPath);

  final Map<String, TextEditingController> _credentialControllers =
      <String, TextEditingController>{};

  late String? _repository = widget.initialRepository;
  late String _domainRoutingMode = widget.initialDomainRoutingMode;
  late String _runtimeSelectionId = widget.initialRuntimeSelectionId;
  late AppDeploymentTlsChallengeMode _tlsChallengeMode =
      widget.initialTlsChallengeMode;
  late String? _dnsProvider = widget.initialDnsProvider;
  late bool _publicHealthCheckEnabled = widget.initialPublicHealthCheckEnabled;

  bool get _supportsDnsTls => widget.availableDnsProviderSpecs.isNotEmpty;

  AppDeploymentDnsProviderSpec? get _selectedDnsSpec {
    // Hoisted so the `== null` check promotes it; a State field is never
    // promoted.
    final dnsProvider = _dnsProvider;
    if (dnsProvider == null) {
      return null;
    }
    return _dnsProviderSpecs[dnsProvider];
  }

  TextEditingController _credentialControllerFor(String key) {
    return _credentialControllers.putIfAbsent(
      key,
      () =>
          TextEditingController(text: widget.initialDnsCredentials[key] ?? ''),
    );
  }

  Map<String, String> _normalizedDnsCredentials(
    AppDeploymentDnsProviderSpec spec,
  ) {
    final normalized = <String, String>{};
    for (final field in spec.fields) {
      final value = _credentialControllerFor(field.key).text.trim();
      if (value.isEmpty) {
        continue;
      }
      normalized[field.key] = value;
    }
    return normalized;
  }

  void _applyRuntimeDefaults(String nextRuntimeId) {
    final previousRuntime = railpackRuntimeForSelection(_runtimeSelectionId);
    final nextRuntime = railpackRuntimeForSelection(nextRuntimeId);
    final currentBuildCommand = _buildCommandController.text.trim();
    final currentRunCommand = _runCommandController.text.trim();
    final currentPort = int.tryParse(_portController.text.trim());

    bool matchesPreviousDefault(String currentValue, String previousValue) {
      return currentValue == previousValue ||
          (currentValue.isEmpty && previousValue.isEmpty);
    }

    if (matchesPreviousDefault(
      currentBuildCommand,
      previousRuntime.defaultBuildCommand,
    )) {
      _buildCommandController.text = nextRuntime.defaultBuildCommand;
    }
    if (matchesPreviousDefault(
      currentRunCommand,
      previousRuntime.defaultRunCommand,
    )) {
      _runCommandController.text = nextRuntime.defaultRunCommand;
    }
    if (currentPort == null || currentPort == previousRuntime.suggestedPort) {
      _portController.text = nextRuntime.suggestedPort.toString();
    }
    _runtimeSelectionId = nextRuntimeId;
  }

  @override
  void dispose() {
    _domainController.dispose();
    _branchController.dispose();
    _portController.dispose();
    _buildCommandController.dispose();
    _runCommandController.dispose();
    _appSubdirectoryController.dispose();
    _publicHealthPathController.dispose();
    for (final controller in _credentialControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final domain = _domainController.text.trim();
    final branch = _branchController.text.trim();
    final parsedPort = int.tryParse(_portController.text.trim()) ?? -1;
    final buildCommand = _buildCommandController.text.trim();
    final runCommand = _runCommandController.text.trim();
    final selectedRuntime = railpackRuntimeForSelection(_runtimeSelectionId);
    final normalizedAppSubdirectory =
        _normalizedDeploymentSettingsAppSubdirectory(
          _appSubdirectoryController.text,
        );

    final normalizedDomainConfig = _isValidDeploymentSettingsDomain(domain)
        ? _normalizedDomainRoutingConfigForWorkspace(
            primaryDomain: domain,
            domainRoutingMode: _domainRoutingMode,
          )
        : null;
    final canonicalDomain = normalizedDomainConfig == null
        ? null
        : _canonicalDomainForWorkspace(
            primaryDomain: normalizedDomainConfig.primaryDomain,
            domainRoutingMode: normalizedDomainConfig.domainRoutingMode,
          );

    final domainError = _isValidDeploymentSettingsDomain(domain)
        ? null
        : 'Enter a valid FQDN.';
    final branchError = _isValidDeploymentSettingsBranch(branch)
        ? null
        : 'Use letters, numbers, ".", "_", "-", "/".';
    final portError = parsedPort >= 1 && parsedPort <= 65535
        ? null
        : 'Port must be 1-65535.';
    final appSubdirectoryError =
        normalizedAppSubdirectory == _invalidAppSubdirectory
        ? 'Use a relative path like "website" (no "." or "..").'
        : null;
    final publicHealthPathError =
        !_publicHealthCheckEnabled ||
            _isValidDeploymentPublicHealthPath(_publicHealthPathController.text)
        ? null
        : 'Use a path that starts with "/", such as "/" or "/health".';

    String? tlsError;
    final dnsSpec = _selectedDnsSpec;
    if (_supportsDnsTls &&
        _tlsChallengeMode == AppDeploymentTlsChallengeMode.dns) {
      if (_dnsProvider == null) {
        tlsError = 'Choose a DNS provider.';
      } else if (dnsSpec == null) {
        tlsError = 'Selected DNS provider is not supported.';
      } else {
        final credentials = _normalizedDnsCredentials(dnsSpec);
        for (final field in dnsSpec.fields) {
          if (!field.required) {
            continue;
          }
          final value = credentials[field.key];
          if (value == null || value.trim().isEmpty) {
            tlsError = '${field.label} is required.';
            break;
          }
        }
        if (tlsError == null && dnsSpec.id == 'cloudns') {
          final hasAuthId = (credentials['auth_id'] ?? '').trim().isNotEmpty;
          final hasSubAuthId = (credentials['sub_auth_id'] ?? '')
              .trim()
              .isNotEmpty;
          if (!hasAuthId && !hasSubAuthId) {
            tlsError = 'Provide Auth ID or Sub-auth ID.';
          }
        }
      }
    }

    // Hoisted so `canSave` promotes it in the callback below. Flow analysis
    // carries a promotion through a local boolean, but a State field is never
    // promoted in the first place.
    final repository = _repository;
    final canSave =
        repository != null &&
        domainError == null &&
        branchError == null &&
        portError == null &&
        appSubdirectoryError == null &&
        publicHealthPathError == null &&
        tlsError == null;

    return AppFormDialog(
      title: 'Review deployment settings',
      description:
          'Start with the basics you need to publish. Open advanced settings only when you need them.',
      maxWidth: 640,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !canSave
              ? null
              : () {
                  final normalizedDomainConfig =
                      _normalizedDomainRoutingConfigForWorkspace(
                        primaryDomain: domain,
                        domainRoutingMode: _domainRoutingMode,
                      );
                  final persistedCanonicalDomain = _canonicalDomainForWorkspace(
                    primaryDomain: normalizedDomainConfig.primaryDomain,
                    domainRoutingMode: normalizedDomainConfig.domainRoutingMode,
                  );
                  final persistedAppSubdirectory =
                      normalizedAppSubdirectory == _invalidAppSubdirectory
                      ? null
                      : normalizedAppSubdirectory;
                  final useDnsChallenge =
                      _supportsDnsTls &&
                      _tlsChallengeMode == AppDeploymentTlsChallengeMode.dns;
                  Navigator.of(context).pop(
                    AppDeploymentSettingsDialogResult(
                      repositoryFullName: repository,
                      primaryDomain: normalizedDomainConfig.primaryDomain,
                      domainRoutingMode:
                          normalizedDomainConfig.domainRoutingMode,
                      canonicalDomain: persistedCanonicalDomain,
                      deployBranch: branch,
                      appPort: parsedPort,
                      railpackProvider: selectedRuntime.provider,
                      railpackBuildCommand: buildCommand,
                      railpackRunCommand: runCommand,
                      appSubdirectory: persistedAppSubdirectory,
                      tlsChallengeMode: useDnsChallenge ? 'dns' : 'http',
                      tlsDnsProvider: useDnsChallenge ? _dnsProvider : null,
                      tlsDnsCredentials: useDnsChallenge && dnsSpec != null
                          ? _normalizedDnsCredentials(dnsSpec)
                          : const <String, String>{},
                      publicHealthCheckEnabled: _publicHealthCheckEnabled,
                      publicHealthCheckPath:
                          _isValidDeploymentPublicHealthPath(
                            _publicHealthPathController.text,
                          )
                          ? _publicHealthPathController.text.trim()
                          : '/',
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
          AppFormSection(
            title: 'Basic settings',
            children: [
              AppSelectFormField<String>(
                key: const Key('github-repo-dropdown'),
                value: _repository,
                labelText: 'Repository',
                items: widget.repositories
                    .map(
                      (repo) => DropdownMenuItem<String>(
                        value: repo.fullName,
                        child: Text(
                          '${repo.fullName}${repo.isPrivate ? ' (private)' : ''}',
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: widget.repositories.isEmpty
                    ? null
                    : (value) {
                        setState(() {
                          _repository = value;
                        });
                      },
              ),
              AppTextFormField(
                key: const Key('deploy-primary-domain-field'),
                controller: _domainController,
                labelText: 'Primary domain',
                hintText: 'app.example.com',
                helperText: canonicalDomain == null
                    ? 'Enter the hostname Deploy Dash should publish.'
                    : 'Canonical host: $canonicalDomain',
                validator: (_) => domainError,
                onChanged: (_) => setState(() {}),
              ),
              Text(
                'Hostname behavior',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                'Choose whether visitors stay on one address or are redirected between www and non-www.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              RadioGroup<String>(
                groupValue: _domainRoutingMode,
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _domainRoutingMode = value;
                  });
                },
                child: Column(
                  children: const [
                    RadioListTile<String>(
                      key: Key('deploy-routing-single-host'),
                      value: _domainRoutingModeSingleHost,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('One hostname only'),
                    ),
                    RadioListTile<String>(
                      key: Key('deploy-routing-www-to-apex'),
                      value: _domainRoutingModeRedirectWwwToApex,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('Main address without www'),
                    ),
                    RadioListTile<String>(
                      key: Key('deploy-routing-apex-to-www'),
                      value: _domainRoutingModeRedirectApexToWww,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('Main address with www'),
                    ),
                  ],
                ),
              ),
              AppTextFormField(
                key: const Key('deploy-branch-field'),
                controller: _branchController,
                labelText: 'Branch',
                validator: (_) => branchError,
                onChanged: (_) => setState(() {}),
              ),
              AppTextFormField(
                key: const Key('deploy-app-subdirectory-field'),
                controller: _appSubdirectoryController,
                labelText: 'App subdirectory (optional)',
                hintText: 'website',
                helperText: 'Leave blank to build from the repository root.',
                validator: (_) => appSubdirectoryError,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
            title: const Text('Advanced settings'),
            subtitle: const Text(
              'Runtime, port, build commands, and certificate options.',
            ),
            children: [
              AppFormSection(
                children: [
                  AppNumberFormField(
                    key: const Key('deploy-app-port-field'),
                    controller: _portController,
                    labelText: 'Web app port',
                    validator: (_) => portError,
                    onChanged: (_) => setState(() {}),
                  ),
                  AppSelectFormField<String>(
                    key: const Key('deploy-runtime-field'),
                    value: _runtimeSelectionId,
                    labelText: 'Runtime',
                    items: railpackRuntimeOptions
                        .map(
                          (runtime) => DropdownMenuItem<String>(
                            value: runtime.id,
                            child: Text(runtime.label),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _applyRuntimeDefaults(value);
                      });
                    },
                  ),
                  AppTextFormField(
                    key: const Key('deploy-build-command-field'),
                    controller: _buildCommandController,
                    labelText: 'Build command',
                    onChanged: (_) => setState(() {}),
                  ),
                  AppTextFormField(
                    key: const Key('deploy-run-command-field'),
                    controller: _runCommandController,
                    labelText: 'Run command',
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    key: const Key('deploy-public-health-enabled-toggle'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Check the public URL after deployment'),
                    subtitle: const Text(
                      'Recommended. A failed check marks the app as needing attention without taking a process-ready release offline.',
                    ),
                    value: _publicHealthCheckEnabled,
                    onChanged: (value) {
                      setState(() {
                        _publicHealthCheckEnabled = value;
                      });
                    },
                  ),
                  if (_publicHealthCheckEnabled)
                    AppTextFormField(
                      key: const Key('deploy-public-health-path-field'),
                      controller: _publicHealthPathController,
                      labelText: 'Public check path',
                      hintText: '/',
                      helperText:
                          'Use the visitor-facing route that should return a successful response.',
                      validator: (_) => publicHealthPathError,
                      onChanged: (_) => setState(() {}),
                    ),
                  const SizedBox(height: 4),
                  if (_supportsDnsTls) ...[
                    Text(
                      'TLS certificates',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    SegmentedButton<AppDeploymentTlsChallengeMode>(
                      segments: const [
                        ButtonSegment<AppDeploymentTlsChallengeMode>(
                          value: AppDeploymentTlsChallengeMode.http,
                          label: Text('Automatic'),
                        ),
                        ButtonSegment<AppDeploymentTlsChallengeMode>(
                          value: AppDeploymentTlsChallengeMode.dns,
                          label: Text('DNS challenge'),
                        ),
                      ],
                      selected: <AppDeploymentTlsChallengeMode>{
                        _tlsChallengeMode,
                      },
                      onSelectionChanged: (selection) {
                        final next = selection.isEmpty
                            ? AppDeploymentTlsChallengeMode.http
                            : selection.first;
                        setState(() {
                          _tlsChallengeMode = next;
                        });
                      },
                    ),
                    Text(
                      _tlsChallengeMode == AppDeploymentTlsChallengeMode.http
                          ? 'Recommended for most deployments.'
                          : 'Use this when you need DNS-based certificates.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_tlsChallengeMode ==
                        AppDeploymentTlsChallengeMode.dns) ...[
                      AppSelectFormField<String>(
                        key: const Key('deploy-dns-provider-field'),
                        value: _dnsProvider,
                        labelText: 'DNS provider',
                        items: widget.availableDnsProviderSpecs
                            .map(
                              (spec) => DropdownMenuItem<String>(
                                value: spec.id,
                                child: Text(spec.label),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (value) {
                          setState(() {
                            _dnsProvider = value;
                          });
                        },
                      ),
                      if (dnsSpec != null) ...[
                        Text(
                          dnsSpec.description,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        for (final field in dnsSpec.fields)
                          AppTextFormField(
                            key: Key(
                              'deploy-dns-${dnsSpec.id}-${field.key}-field',
                            ),
                            controller: _credentialControllerFor(field.key),
                            obscureText: field.secret,
                            labelText: field.label,
                            hintText: field.hintText,
                            onChanged: (_) => setState(() {}),
                          ),
                      ],
                      if (tlsError != null)
                        Text(
                          tlsError,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: YaruColors.red),
                        ),
                    ],
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
