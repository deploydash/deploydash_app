import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Architecture invariant: Drift rows stay behind the mapper.
///
/// `AGENTS.md` states two rules that the layer-direction check in
/// `layering_test.dart` does not cover, because both are about *what* crosses
/// the boundary rather than which way the arrow points:
///
/// > Drift row classes are named `…Row` and never leave `data/local/`.
/// > Repositories map rows to domain types at that edge, and that mapper is
/// > the only place both shapes are known. No `jsonDecode` of a database
/// > column happens above it.
///
/// The first is checked exactly: every `@DataClassName` in the schema is a
/// name that must not appear above `data/local`. The second cannot be decided
/// statically — whether a decoded string came from a column is a question
/// about values, not text — so it is checked through its mechanism. A column
/// can only reach a file above `data/local` if that file can see the Drift
/// schema, so the set of files that import it is pinned and may only shrink.
/// Today all seven need the `AppDatabase` handle itself, not a row.
///
/// Added by T-2.6.3. Written against the rule rather than against a violation:
/// both checks pass on the current tree, which is what a guard is for.
final _dataClassName = RegExp(r"@DataClassName\('([A-Za-z0-9_]+)'\)");
final _libraryDirective = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Files above `data/local` that import the Drift schema, measured 2026-09-04.
///
/// Each needs the `AppDatabase` type or its provider — the connection handle —
/// rather than a row class. The list may only shrink: an addition means a new
/// place a column could be read and decoded without passing a mapper, which
/// is the thing the rule forbids.
const _schemaImportersOutsideDataLocal = <String>{
  'main.dart',
  'providers/app_settings_provider.dart',
  'providers/database_unlock_provider.dart',
  'providers/server_provider.dart',
  'services/desktop_update_service.dart',
  'services/sqlite_backup_service.dart',
  'services/ssh_service.dart',
};

Iterable<File> _dartFiles(Directory directory) sync* {
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
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
  late Directory libDirectory;
  late List<File> sources;

  setUpAll(() {
    final root = findRepositoryRoot();
    libDirectory = Directory('${root.path}/ui/lib');
    expect(libDirectory.existsSync(), isTrue, reason: 'desktop lib must exist');
    sources = _dartFiles(libDirectory).toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    expect(sources, isNotEmpty, reason: 'the guard must scan production Dart');
  });

  test('no Drift row class is named outside data/local', () {
    final schema = File('${libDirectory.path}/data/local/app_database.dart');
    expect(schema.existsSync(), isTrue, reason: 'the Drift schema must exist');
    final rowNames = _dataClassName
        .allMatches(schema.readAsStringSync())
        .map((match) => match.group(1)!)
        .toSet();
    expect(
      rowNames.length,
      greaterThan(30),
      reason: 'the scan must see the real schema, not an empty one',
    );
    final rowWord = RegExp('\\b(${rowNames.join('|')})\\b');

    final violations = <String>[];
    for (final source in sources) {
      final path = _relativeToLib(file: source, libDirectory: libDirectory);
      if (path.startsWith('data/local/')) {
        continue;
      }
      final named = rowWord
          .allMatches(source.readAsStringSync())
          .map((match) => match.group(1)!)
          .toSet();
      if (named.isNotEmpty) {
        violations.add('$path names ${named.toList()..sort()}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'A Drift row above data/local means two places know the row shape, '
          'and the repository mapper stops being the only one:\n'
          '${violations.join('\n')}',
    );
  });

  test('the set of files that can see a database column only shrinks', () {
    final importers = <String>{};
    for (final source in sources) {
      final path = _relativeToLib(file: source, libDirectory: libDirectory);
      if (path.startsWith('data/local/')) {
        continue;
      }
      for (final match in _libraryDirective.allMatches(
        source.readAsStringSync(),
      )) {
        if (match.group(1)!.endsWith('app_database.dart')) {
          importers.add(path);
        }
      }
    }

    final added = importers.difference(_schemaImportersOutsideDataLocal);
    expect(
      added,
      isEmpty,
      reason:
          'A new file above data/local can now see the Drift schema, which is '
          'how a column reaches code that has not passed a mapper. Take the '
          'value from a repository instead, or add it deliberately with a '
          'reason:\n${(added.toList()..sort()).join('\n')}',
    );

    final removed = _schemaImportersOutsideDataLocal.difference(importers);
    expect(
      removed,
      isEmpty,
      reason:
          'These no longer import the schema. Remove them from the pinned set '
          'in the same commit, or the ratchet stops ratcheting:\n'
          '${(removed.toList()..sort()).join('\n')}',
    );
  });
}
