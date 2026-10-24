import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/e2e_checklist.dart';

/// Guard-first pin for the slim macOS QA leg (`DEPLOYDASH_E2E_SLIM_MACOS`).
/// The pinned set is the primitive the live run validates against in
/// `_validateSlimMacOsResults`; this test pins the pin itself, so extending
/// the slim flow requires updating the count here deliberately rather than
/// silently widening what slim means.
void main() {
  test('slim macOS checklist set is pinned', () {
    expect(slimMacOsChecklistKeys.length, 31);
    for (final key in <String>[
      'Core App Shell::Local database creation and unlock',
      'Server Onboarding::Successful baseline setup',
      'Project Web App::PHP/Laravel deploy',
      'Project Web App::Successful deploy state',
      'Remote Server Stack Verification::Caddy runtime through app deploy',
    ]) {
      expect(slimMacOsChecklistKeys, contains(key));
    }
    for (final key in slimMacOsChecklistKeys) {
      expect(key, contains('::'));
    }
  });

  test('unexpected slim macOS keys are reported', () {
    expect(
      slimMacOsUnexpectedKeys(const <String>[
        'Core App Shell::Home dashboard after setup',
      ]),
      isEmpty,
    );
    expect(slimMacOsUnexpectedKeys(const <String>['Bogus::Key']), <String>[
      'Bogus::Key',
    ]);
  });

  group('repository root and checklist overrides', () {
    test('explicit repo root override wins over the walk-up', () async {
      final temp = await Directory.systemTemp.createTemp('slim-guard');
      try {
        await Directory('${temp.path}/ui').create();
        await Directory('${temp.path}/orchestrator').create();
        await File('${temp.path}/ui/pubspec.yaml').writeAsString('name: ui\n');
        await File(
          '${temp.path}/orchestrator/pyproject.toml',
        ).writeAsString('[project]\nname = "orchestrator"\n');
        final root = findRepositoryRoot(
          start: Directory(temp.parent.path),
          repoRootOverride: temp.path,
        );
        expect(root.path, temp.path);
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('bogus repo root override fails loudly', () async {
      final temp = await Directory.systemTemp.createTemp('slim-guard');
      try {
        expect(
          () => findRepositoryRoot(repoRootOverride: temp.path),
          throwsStateError,
        );
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('checklist path override reads the given file', () async {
      final temp = await Directory.systemTemp.createTemp('slim-guard');
      try {
        final checklist = File('${temp.path}/checklist.md');
        await checklist.writeAsString(
          '## Demo Section\n\n| Done | Surface | Status | Notes |\n'
          '| --- | --- | --- | --- |\n'
          '| [x] | Demo surface | done | notes |\n',
        );
        final surfaces = readManualE2eChecklist(
          checklistPathOverride: checklist.path,
        );
        expect(surfaces, isNotEmpty);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
