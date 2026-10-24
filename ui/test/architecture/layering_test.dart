import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Architecture invariant: production Dart imports follow the desktop layer
/// direction. Shared value layers may be imported by every layer, but they do
/// not import orchestration, persistence, or presentation code themselves.
///
/// This scans import and export directives, rather than exercising widgets,
/// because one forbidden directive is enough to reverse a dependency. Rules
/// are listed per source layer so new cross-layer imports cannot hide behind a
/// one-direction-only check.
enum _Layer { ui, providers, services, dataLocal, models, domain, utils }

const _allowedTargets = <_Layer, Set<_Layer>>{
  _Layer.ui: <_Layer>{
    _Layer.ui,
    _Layer.providers,
    _Layer.services,
    _Layer.models,
    _Layer.domain,
    _Layer.utils,
  },
  _Layer.providers: <_Layer>{
    _Layer.providers,
    _Layer.services,
    _Layer.dataLocal,
    _Layer.models,
    _Layer.domain,
    _Layer.utils,
  },
  _Layer.services: <_Layer>{
    _Layer.services,
    _Layer.dataLocal,
    _Layer.models,
    _Layer.domain,
    _Layer.utils,
  },
  _Layer.dataLocal: <_Layer>{
    _Layer.dataLocal,
    _Layer.models,
    _Layer.domain,
    _Layer.utils,
  },
  _Layer.models: <_Layer>{_Layer.models, _Layer.domain, _Layer.utils},
  _Layer.domain: <_Layer>{_Layer.models, _Layer.domain, _Layer.utils},
  _Layer.utils: <_Layer>{_Layer.models, _Layer.domain, _Layer.utils},
};

final _libraryDirective = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

Iterable<File> _dartFiles(Directory directory) sync* {
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

_Layer? _layerForRelativePath(String path) {
  if (path.startsWith('data/local/')) {
    return _Layer.dataLocal;
  }
  if (path.startsWith('ui/')) {
    return _Layer.ui;
  }
  if (path.startsWith('providers/')) {
    return _Layer.providers;
  }
  if (path.startsWith('services/')) {
    return _Layer.services;
  }
  if (path.startsWith('models/')) {
    return _Layer.models;
  }
  if (path.startsWith('domain/')) {
    return _Layer.domain;
  }
  if (path.startsWith('utils/')) {
    return _Layer.utils;
  }
  return null;
}

File? _resolveLibraryUri({
  required File source,
  required String uri,
  required Directory libDirectory,
}) {
  if (uri.startsWith('dart:')) {
    return null;
  }
  if (uri.startsWith('package:')) {
    const packagePrefix = 'package:ui/';
    if (!uri.startsWith(packagePrefix)) {
      return null;
    }
    return File('${libDirectory.path}/${uri.substring(packagePrefix.length)}');
  }
  return File.fromUri(source.uri.resolve(uri));
}

String _relativeToLib({required File file, required Directory libDirectory}) {
  final libPath = '${libDirectory.absolute.path}${Platform.pathSeparator}';
  final filePath = file.absolute.path;
  if (!filePath.startsWith(libPath)) {
    return '';
  }
  return filePath.substring(libPath.length).replaceAll('\\', '/');
}

void main() {
  test('production Dart imports respect every desktop layer boundary', () {
    final root = findRepositoryRoot();
    final libDirectory = Directory('${root.path}/ui/lib');
    expect(libDirectory.existsSync(), isTrue, reason: 'desktop lib must exist');

    final violations = <String>[];
    final sources = _dartFiles(libDirectory).toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    expect(sources, isNotEmpty, reason: 'the guard must scan production Dart');

    for (final source in sources) {
      final sourcePath = _relativeToLib(
        file: source,
        libDirectory: libDirectory,
      );
      final sourceLayer = _layerForRelativePath(sourcePath);
      if (sourceLayer == null) {
        continue;
      }
      final allowed = _allowedTargets[sourceLayer]!;
      final text = source.readAsStringSync();
      for (final match in _libraryDirective.allMatches(text)) {
        final uri = match.group(1)!;
        final target = _resolveLibraryUri(
          source: source,
          uri: uri,
          libDirectory: libDirectory,
        );
        if (target == null) {
          continue;
        }
        final targetPath = _relativeToLib(
          file: target,
          libDirectory: libDirectory,
        );
        final targetLayer = _layerForRelativePath(targetPath);
        if (targetLayer == null || allowed.contains(targetLayer)) {
          continue;
        }
        violations.add(
          '$sourcePath (${_layerName(sourceLayer)}) imports $targetPath '
          '(${_layerName(targetLayer)}) via $uri',
        );
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Forbidden production-layer imports:\n${violations.join('\n')}',
    );
  });
}

String _layerName(_Layer layer) {
  return switch (layer) {
    _Layer.ui => 'ui',
    _Layer.providers => 'providers',
    _Layer.services => 'services',
    _Layer.dataLocal => 'data/local',
    _Layer.models => 'models',
    _Layer.domain => 'domain',
    _Layer.utils => 'utils',
  };
}
