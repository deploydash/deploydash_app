part of '../server_management_view.dart';

extension _ServicesTabOperations on _ServicesTabState {
  Future<void> _enableService(String serviceId) async {
    if (!_supportsRuntimeManagement(serviceId)) {
      final service = _serviceById(serviceId);
      final label = service?.name ?? 'This service';
      _showServiceMessage('$label cannot be enabled from this screen yet.');
      return;
    }
    if (serviceId == 'proxy') {
      await _runWebServerAction(
        operationId: 'service_enable',
        statusAfterSuccess: const ContainerRuntimeStatus.ready(),
        settings: _buildWebServerSettings(_webServerConfig),
      );
      return;
    }
    if (serviceId == 'database') {
      final configured = await _showPostgresConfigureDialog(
        context: context,
        initialConfig: _postgresConfig,
        title: 'Enable database service',
        saveButtonLabel: 'Enable',
        // A fresh service has no live data: the version picker stays.
        lockVersion: false,
      );
      if (configured == null) {
        return;
      }
      final persistedConfig = await _persistPostgresConfigWithPassword(
        configured,
      );
      _postgresConfig = persistedConfig;
      await _runDatabaseAction(
        operationId: 'service_enable',
        statusAfterSuccess: const ContainerRuntimeStatus.ready(),
        settings: buildPostgresServiceSettings(persistedConfig),
        showSuccessMessage: 'Database service enabled.',
      );
    }
  }

  Future<void> _restartService(String serviceId) async {
    if (!_supportsRuntimeManagement(serviceId)) {
      final service = _serviceById(serviceId);
      final label = service?.name ?? 'This service';
      _showServiceMessage('$label cannot be restarted from this screen yet.');
      return;
    }
    if (serviceId == 'proxy') {
      await _runWebServerAction(
        operationId: 'service_restart',
        statusAfterSuccess: const ContainerRuntimeStatus.ready(),
      );
      return;
    }
    if (serviceId == 'database') {
      await _runDatabaseAction(
        operationId: 'service_restart',
        statusAfterSuccess: const ContainerRuntimeStatus.ready(),
      );
    }
  }

  Future<void> _toggleServiceState(String serviceId) async {
    final service = _serviceById(serviceId);
    if (service == null) {
      return;
    }

    if (serviceId == 'proxy') {
      if (service.status.isProcessActive) {
        await _runWebServerAction(
          operationId: 'service_stop',
          statusAfterSuccess: const ContainerRuntimeStatus.stopped(),
        );
      } else {
        await _runWebServerAction(
          operationId: 'service_start',
          statusAfterSuccess: const ContainerRuntimeStatus.ready(),
        );
      }
      return;
    }
    if (serviceId == 'database') {
      if (service.status.isProcessActive) {
        await _runDatabaseAction(
          operationId: 'service_stop',
          statusAfterSuccess: const ContainerRuntimeStatus.stopped(),
        );
      } else {
        await _runDatabaseAction(
          operationId: 'service_start',
          statusAfterSuccess: const ContainerRuntimeStatus.ready(),
        );
      }
      return;
    }
    _showServiceMessage(
      '${service.name} start/stop controls are not available yet.',
    );
  }

  void _patchService(
    String serviceId,
    _ServerServiceRecord Function(_ServerServiceRecord service) transform,
  ) {
    _applyState(() {
      _services = _services
          .map(
            (service) => service.id == serviceId ? transform(service) : service,
          )
          .toList(growable: false);
    });
  }

  Future<void> _openConfigureModal(_ServerServiceRecord service) async {
    if (service.id == 'database') {
      final result = await _showPostgresConfigureDialog(
        context: context,
        initialConfig: _postgresConfig,
        title: 'Database settings',
        saveButtonLabel: 'Save',
        // A running service keeps its data directory: the dialog fixes the
        // version and offers the upgrade flow instead of the picker.
        lockVersion: true,
        upgradeBlockedReason: service.status.isReady
            ? null
            : postgresUpgradeNotReadyReason(),
      );

      if (result == null) {
        return;
      }

      // The locked dialog only returns a different version through the
      // upgrade flow, so a changed version dispatches the upgrade rather
      // than a configure the engine guard would refuse.
      if (result.postgresVersion != _postgresConfig.postgresVersion) {
        await _upgradePostgresMajor(result);
        return;
      }

      final persistedConfig = await _persistPostgresConfigWithPassword(result);
      _postgresConfig = persistedConfig;
      await _runDatabaseAction(
        operationId: 'service_configure',
        statusAfterSuccess:
            _serviceById('database')?.status ??
            const ContainerRuntimeStatus.ready(),
        settings: buildPostgresServiceSettings(persistedConfig),
        showSuccessMessage: 'Database service settings saved.',
      );
      return;
    }
    if (service.id != 'proxy') {
      _showServiceMessage(servicesConfigureUnavailableMessage(service.name));
      return;
    }

    final result = await _showWebServerConfigureDialog(
      context: context,
      serviceId: service.id,
      initialConfig: _webServerConfig,
    );
    if (result == null) {
      return;
    }

    _webServerConfig = result;
    final saved = await _runWebServerAction(
      operationId: 'service_configure',
      statusAfterSuccess:
          _serviceById('proxy')?.status ?? const ContainerRuntimeStatus.ready(),
      settings: _buildWebServerSettings(result),
      showSuccessMessage: 'Web server settings saved.',
    );
    if (saved && widget.server != null) {
      await ref
          .read(serverCatalogProvider.notifier)
          .updateSelectedServerWebServerConfig(result);
    }
  }

  _ServerServiceRecord? _serviceById(String serviceId) {
    for (final service in _services) {
      if (service.id == serviceId) {
        return service;
      }
    }
    return null;
  }
}
