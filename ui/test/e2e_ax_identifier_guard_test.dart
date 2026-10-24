import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for production accessibility identifiers used by exact-artifact
/// macOS automation.
///
/// Flutter `Key`s never reach the platform accessibility tree, so XCTest is
/// blind to every control until each package-boundary key is mirrored as
/// `Semantics(identifier: '<same-as-key>')`. These identifiers ship in the
/// notarized application: a test-only build would not certify the DMG.
///
/// - form fields, selects, and toggles: auto-exposed by the shared
///   primitives in `app_forms.dart` from the widget or field key;
/// - contextual navigation destinations (`*-nav-*`): auto-exposed by the
///   single interpolation owner in `app_context_navigation.dart`;
/// - everything else (buttons, cards, tabs, status text): explicit
///   per-site `AppAccessibilityIdentifier` wraps.
///
/// Extending the slim flow means extending these sets deliberately, never by
/// accident. Each set asserts its count, mirroring `slim_macos_guard_test`.
void main() {
  /// Reads a file under the application checkout's `ui/` directory.
  String readUiFile(String relativePath) {
    var current = Directory.current;
    while (true) {
      final candidate = File('${current.path}/ui/$relativePath');
      if (candidate.existsSync()) {
        return candidate.readAsStringSync();
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        fail('Could not find ui/$relativePath from ${Directory.current.path}.');
      }
      current = parent;
    }
  }

  /// Reads a file under the application checkout's `ui/` directory.
  String readUiLib(String relativePath) {
    return readUiFile('lib/$relativePath');
  }

  /// Scans every Dart file under `ui/lib` for [pattern].
  bool libContains(Pattern pattern) {
    var current = Directory.current;
    while (true) {
      final lib = Directory('${current.path}/ui/lib');
      if (lib.existsSync()) {
        for (final entity in lib.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.dart')) {
            if (pattern.allMatches(entity.readAsStringSync()).isNotEmpty) {
              return true;
            }
          }
        }
        return false;
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        fail('Could not find ui/lib from ${Directory.current.path}.');
      }
      current = parent;
    }
  }

  // Form fields/selects/toggles auto-exposed by the shared primitives from
  // the widget's own key. Each must still be attached at its call site.
  const fieldKeys = <String>{
    'database-passphrase-field',
    'database-confirm-passphrase-field',
    'server-name-field',
    'server-host-field',
    'server-port-field',
    'server-user-field',
    'server-password-field',
  };

  // Contextual navigation destinations auto-exposed by the single
  // interpolation owner.
  const navKeys = <String>{'app-settings-nav-updates'};

  // Buttons, cards, tabs, and status surfaces with explicit per-site wraps.
  // `server-save-blocked-compatibility` and `database-passphrase-submit`
  // are covered structurally below (shared blocking-reason owner and a mode
  // conditional), so they are pinned there rather than here.
  const explicitKeys = <String>{
    'server-onboarding-start-button',
    'server-check-button',
    'server-compatibility-summary',
    'server-save-button',
    'server-setup-progress-card',
    'server-setup-failure-message',
    'services-selection-continue-button',
    'app-settings-update-status',
    'app-settings-check-updates-button',
  };

  test('production accessibility identifier helper is always enabled', () {
    final helper = readUiLib('ui/system/app_accessibility_identifier.dart');
    expect(helper, isNot(contains('DEPLOYDASH_E2E_AX_IDENTIFIERS')));
    expect(helper, contains('class AppAccessibilityIdentifier'));
    expect(helper, contains('Semantics(identifier:'));
  });

  test('app startup never force-enables semantics', () {
    // Forcing the tree at startup poisoned the macOS bridge
    // (flutter/flutter#158399): gate on plus VoiceOver stayed empty while
    // gate off plus VoiceOver populated, so the forcing call was deleted.
    // The production identifier widgets publish on demand once an AX client
    // arms the bridge; main() must not switch collection on itself.
    final main = readUiLib('main.dart');
    expect(main, isNot(contains('ensureE2eSemantics')));
  });

  test('shared form primitives auto-expose their key', () {
    final forms = readUiLib('ui/system/app_forms.dart');
    expect(forms, contains('appAccessibilityIdentifierForKeys('));
    // All three keyed primitives must route through the wrapper; a new
    // keyed primitive that bypasses it would leave its fields invisible.
    expect(
      'appAccessibilityIdentifierForKeys('.allMatches(forms).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('contextual navigation auto-exposes destination keys', () {
    final nav = readUiLib('ui/system/app_context_navigation.dart');
    expect(nav, contains('identifier:'));
    expect(nav, contains(r"'$keyNamespace-nav-${item.id}'"));
  });

  test('slim field keys are still attached in lib', () {
    expect(fieldKeys.length, 7);
    for (final key in fieldKeys) {
      expect(
        libContains("Key('$key')"),
        isTrue,
        reason: 'No widget in ui/lib carries Key(\'$key\') anymore.',
      );
    }
  });

  test('slim nav keys resolve through the interpolation owner', () {
    expect(navKeys.length, 1);
    for (final key in navKeys) {
      final namespace = key.substring(0, key.indexOf('-nav-'));
      expect(
        libContains("navigationKeyNamespace: '$namespace'"),
        isTrue,
        reason: 'No workspace passes navigation namespace $namespace.',
      );
    }
  });

  test('database submit mirrors its mode conditional identifier', () {
    final gate = readUiLib('ui/startup/database_unlock_gate.dart');
    expect(gate, contains('identifier: isRestoreMode'));
    expect(gate, contains("'database-passphrase-submit'"));
    expect(gate, contains("'database-restore-submit'"));
  });

  test('package-boundary explicit keys carry an AX identifier', () {
    expect(explicitKeys.length, 9);
    for (final key in explicitKeys) {
      expect(
        libContains("identifier: '$key'"),
        isTrue,
        reason: 'No Semantics identifier mirrors E2E key \'$key\'.',
      );
    }
  });

  test('package-boundary coverage gate measures lines and branches', () {
    final coverage = readUiFile(
      'scripts/package_boundary_accessibility_coverage.sh',
    );
    expect(coverage, contains('--branch-coverage'));
    expect(coverage, contains('app_accessibility_identifier_test.dart'));
    expect(coverage, contains('e2e_ax_identifier_guard_test.dart'));
    expect(coverage, contains('BRDA:'));
    expect(coverage, contains('100.00% line and branch coverage'));
  });

  test('no launch-argument profile reset survives', () {
    // Owner decision: fresh profiles come from wiped containers (manual
    // Finder delete on desk) and virgin hosted runners — never from an
    // in-binary flag. This pins the removal: reintroducing the literal
    // anywhere below fails here with the file list.
    const flag = '--e2e-fresh-profile';
    final hits = <String>[];
    var current = Directory.current;
    while (true) {
      final ui = Directory('${current.path}/ui');
      if (ui.existsSync()) {
        for (final root in ['lib', 'macos/RunnerUITests', 'scripts']) {
          final dir = Directory('${ui.path}/$root');
          if (!dir.existsSync()) {
            continue;
          }
          for (final entity in dir.listSync(recursive: true)) {
            if (entity is! File || entity.path == Platform.script.path) {
              continue;
            }
            if (entity.readAsStringSync().contains(flag)) {
              hits.add(entity.path);
            }
          }
        }
        expect(
          hits,
          isEmpty,
          reason: 'Launch-argument profile reset reintroduced in: $hits.',
        );
        return;
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        fail('Could not find ui/ from ${Directory.current.path}.');
      }
      current = parent;
    }
  });
}
