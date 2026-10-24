import 'dart:io';

import 'package:ui/native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildNativeBridgeLoadPlan', () {
    test('builds Linux bridge candidates from executable path', () {
      final plan = buildNativeBridgeLoadPlan(
        operatingSystem: 'linux',
        executablePath: '/opt/deploydash/deploydash',
        environment: const {},
      );

      expect(plan.executableDir, '/opt/deploydash');
      expect(plan.eagerCandidates, ['libbridge.so']);
      expect(plan.fallbackCandidates, [
        '/opt/deploydash/libbridge.so',
        '/opt/deploydash/lib/libbridge.so',
      ]);
    });

    test('builds macOS bridge candidates with app bundle fallback', () {
      final plan = buildNativeBridgeLoadPlan(
        operatingSystem: 'macos',
        executablePath:
            '/Applications/Deploy Dash.app/Contents/MacOS/deploydash',
        environment: const {},
      );

      expect(plan.eagerCandidates, isEmpty);
      expect(plan.fallbackCandidates, [
        '/Applications/Deploy Dash.app/Contents/MacOS/libbridge.dylib',
        '/Applications/Deploy Dash.app/Contents/MacOS/../Frameworks/libbridge.dylib',
        'libbridge.dylib',
        'Frameworks/libbridge.dylib',
        'ui.framework/ui',
        'process exports',
      ]);
    });

    test('keeps override path when provided', () {
      final plan = buildNativeBridgeLoadPlan(
        operatingSystem: 'windows',
        executablePath: r'C:\Program Files\Deploy Dash\deploydash.exe',
        environment: const {'DEPLOYDASH_BRIDGE_PATH': r'D:\custom\bridge.dll'},
      );

      expect(plan.overridePath, r'D:\custom\bridge.dll');
      expect(plan.executableDir, r'C:\Program Files\Deploy Dash');
      expect(plan.eagerCandidates, isEmpty);
      expect(plan.fallbackCandidates, [
        r'C:\Program Files\Deploy Dash\bridge.dll',
        r'C:\Program Files\Deploy Dash\libbridge.dll',
        'process exports',
      ]);
    });

    test('maps a missing override to null on every branch', () {
      for (final operatingSystem in ['linux', 'macos', 'windows', 'fuchsia']) {
        final plan = buildNativeBridgeLoadPlan(
          operatingSystem: operatingSystem,
          executablePath: '/opt/deploydash/deploydash',
          environment: const {},
        );
        expect(
          plan.overridePath,
          isNull,
          reason: 'missing override on $operatingSystem',
        );
      }
    });

    test('maps an empty override to null on every branch', () {
      for (final operatingSystem in ['linux', 'macos', 'windows', 'fuchsia']) {
        final plan = buildNativeBridgeLoadPlan(
          operatingSystem: operatingSystem,
          executablePath: '/opt/deploydash/deploydash',
          environment: const {'DEPLOYDASH_BRIDGE_PATH': ''},
        );
        expect(
          plan.overridePath,
          isNull,
          reason: 'empty override on $operatingSystem',
        );
      }
    });

    test('trims the override and maps whitespace-only to null', () {
      final trimmed = buildNativeBridgeLoadPlan(
        operatingSystem: 'linux',
        executablePath: '/opt/deploydash/deploydash',
        environment: const {
          'DEPLOYDASH_BRIDGE_PATH': '  /opt/custom/libbridge.so  ',
        },
      );
      expect(trimmed.overridePath, '/opt/custom/libbridge.so');

      final blank = buildNativeBridgeLoadPlan(
        operatingSystem: 'linux',
        executablePath: '/opt/deploydash/deploydash',
        environment: const {'DEPLOYDASH_BRIDGE_PATH': '   '},
      );
      expect(blank.overridePath, isNull);
    });

    test('keeps the override on the linux, macos, and unknown branches', () {
      final linux = buildNativeBridgeLoadPlan(
        operatingSystem: 'linux',
        executablePath: '/opt/deploydash/deploydash',
        environment: const {
          'DEPLOYDASH_BRIDGE_PATH': '/opt/custom/libbridge.so',
        },
      );
      expect(linux.overridePath, '/opt/custom/libbridge.so');

      final macos = buildNativeBridgeLoadPlan(
        operatingSystem: 'macos',
        executablePath:
            '/Applications/Deploy Dash.app/Contents/MacOS/deploydash',
        environment: const {
          'DEPLOYDASH_BRIDGE_PATH': '/opt/custom/libbridge.dylib',
        },
      );
      expect(macos.overridePath, '/opt/custom/libbridge.dylib');

      final unknown = buildNativeBridgeLoadPlan(
        operatingSystem: 'fuchsia',
        executablePath: '/opt/deploydash/deploydash',
        environment: const {'DEPLOYDASH_BRIDGE_PATH': '/opt/custom/bridge'},
      );
      expect(unknown.overridePath, '/opt/custom/bridge');
    });
  });

  group('native bridge collapse shape (D-31 pin)', () {
    test('wrappers and the override ternary each have one owner', () {
      final source = File('lib/native_bridge.dart').readAsStringSync();
      expect('_callString'.allMatches(source).length, 5);
      expect('overridePath == null'.allMatches(source).length, 1);
      // The nine lookups stay spelled out: a generic lookup helper does
      // not compile (FFI `non_constant_type_argument` -- type arguments
      // must be constant types). Pinned so a retry notices the decision.
      expect('lookup<NativeFunction'.allMatches(source).length, 9);
    });
  });

  group('NativeBridge.setDeployDashDataDir', () {
    test('rejects an empty data directory before loading the bridge', () {
      expect(
        () => NativeBridge().setDeployDashDataDir('   '),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('NativeBridgeRuntimeDiagnostics', () {
    test('parses structured diagnostics', () {
      final diagnostics = NativeBridgeRuntimeDiagnostics.tryParse(
        '{"status":"error","msg":"runtime missing","platform":"linux",'
        '"exe_dir":"/opt/deploydash","libpython_path":"/opt/python/libpython3.13.so",'
        '"python_home":"/opt/python","backend_runtime_present":false,'
        '"search_paths":["/opt/data/py/site-packages"],'
        '"process_security":{"required":true,"effective":false,'
        '"platform":"linux","controls":{"dumpable":1},'
        '"errors":["not hardened"]}}',
      );

      expect(diagnostics, isNotNull);
      expect(diagnostics!.isError, isTrue);
      expect(diagnostics.backendRuntimePresent, isFalse);
      expect(
        diagnostics.describeForError(),
        contains('backend_runtime_present=false'),
      );
      expect(
        diagnostics.describeForError(),
        contains('search_paths=/opt/data/py/site-packages'),
      );
      expect(diagnostics.processSecurity!.required, isTrue);
      expect(diagnostics.processSecurity!.effective, isFalse);
      expect(diagnostics.processSecurity!.controls['dumpable'], 1);
      expect(
        diagnostics.describeForError(),
        contains('process_security_errors=not hardened'),
      );
    });

    test('returns null for malformed diagnostics payload', () {
      expect(NativeBridgeRuntimeDiagnostics.tryParse('not-json'), isNull);
    });

    test('keeps legacy diagnostics without process security', () {
      final diagnostics = NativeBridgeRuntimeDiagnostics.tryParse(
        '{"status":"ready","msg":"ready","search_paths":[]}',
      );

      expect(diagnostics, isNotNull);
      expect(diagnostics!.processSecurity, isNull);
    });
  });

  group('ProcessSecurityDiagnostics', () {
    test('rejects missing and invalid required fields', () {
      expect(ProcessSecurityDiagnostics.tryParse(null), isNull);
      expect(ProcessSecurityDiagnostics.tryParse(<String, Object?>{}), isNull);
      expect(
        ProcessSecurityDiagnostics.tryParse(<String, Object?>{
          'required': 'yes',
          'effective': true,
          'platform': 'linux',
        }),
        isNull,
      );
    });

    test('uses empty diagnostics for malformed optional fields', () {
      final diagnostics = ProcessSecurityDiagnostics.tryParse(<String, Object?>{
        'required': false,
        'effective': true,
        'platform': 'windows',
        'controls': 'invalid',
        'errors': 'invalid',
      });

      expect(diagnostics, isNotNull);
      expect(diagnostics!.controls, isEmpty);
      expect(diagnostics.errors, isEmpty);
      expect(
        diagnostics.describeForError(),
        'process_security_required=false, process_security_effective=true, '
        'process_security_platform=windows',
      );
    });
  });
}
