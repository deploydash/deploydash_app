import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readRepositoryFile(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: 'Missing $relativePath');
  return file.readAsStringSync();
}

Iterable<File> _dartFilesBelow(String relativeDirectory) {
  final directory = Directory(relativeDirectory);
  expect(directory.existsSync(), isTrue, reason: 'Missing $relativeDirectory');
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
}

void main() {
  test('server JSON blobs have one versioned data-layer codec boundary', () {
    const storageColumns = <String>[
      'serviceWebServerConfigJson',
      'servicePostgresConfigJson',
      'serviceFirewallConfigJson',
      'serviceSystemConfigJson',
      'managedSoftwareStatusJson',
    ];
    final codec = _readRepositoryFile(
      'lib/data/local/server_config_json_codecs.dart',
    );
    final repository = _readRepositoryFile(
      'lib/data/local/server_repository.dart',
    );

    expect(codec, contains('const int currentServerConfigJsonVersion = 1;'));
    expect(codec, contains("'version'"));
    expect(codec, contains("'payload'"));
    expect(repository, contains('ServerConfigJsonCodecs.webServer'));
    expect(repository, contains('ServerConfigJsonCodecs.managedSoftware'));
    expect(repository, isNot(contains('_decodeServerConfigJsonMap')));

    for (final file in _dartFilesBelow('lib')) {
      final path = file.path.replaceAll('\\', '/');
      if (path.startsWith('lib/data/local/')) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final column in storageColumns) {
        expect(
          source,
          isNot(contains(column)),
          reason: '${file.path} leaks persisted $column outside data/local',
        );
      }
    }
  });
}
