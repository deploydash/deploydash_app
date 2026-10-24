import 'package:ui/models/railpack_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('railpack runtime helpers', () {
    test(
      'normalizeRailpackProvider accepts known providers case-insensitively',
      () {
        expect(normalizeRailpackProvider(' Python '), 'python');
        expect(normalizeRailpackProvider('NODE'), 'node');
        expect(normalizeRailpackProvider('staticfile'), 'staticfile');
      },
    );

    test('normalizeRailpackProvider rejects unknown providers', () {
      expect(normalizeRailpackProvider(null), isNull);
      expect(normalizeRailpackProvider(''), isNull);
      expect(normalizeRailpackProvider('rails'), isNull);
    });

    test(
      'railpackRuntimeForSelection returns matching option or auto-detect',
      () {
        expect(
          railpackRuntimeForSelection('python'),
          same(railpackRuntimeOptions[2]),
        );
        expect(
          railpackRuntimeForSelection(' STATICFILE '),
          same(railpackRuntimeOptions.last),
        );
        expect(
          railpackRuntimeForSelection('unknown-runtime'),
          same(railpackAutoDetectRuntime),
        );
      },
    );

    test(
      'railpackRuntimeForProvider returns matching option or auto-detect',
      () {
        expect(railpackRuntimeForProvider('php').id, 'php');
        expect(railpackRuntimeForProvider(' DotNet ').id, 'dotnet');
        expect(
          railpackRuntimeForProvider('unsupported'),
          same(railpackAutoDetectRuntime),
        );
      },
    );

    test('railpackRuntimeSelectionId prefers explicit provider', () {
      expect(
        railpackRuntimeSelectionId(
          railpackProvider: 'python',
          railpackBuildCommand: 'npm run build',
          railpackRunCommand: 'npm run start',
        ),
        'python',
      );
    });

    test('railpackRuntimeSelectionId maps legacy node defaults to node', () {
      expect(
        railpackRuntimeSelectionId(
          railpackProvider: null,
          railpackBuildCommand: ' npm run build ',
          railpackRunCommand: ' npm run start ',
        ),
        'node',
      );
    });

    test('railpackRuntimeSelectionId falls back to auto-detect', () {
      expect(
        railpackRuntimeSelectionId(
          railpackProvider: null,
          railpackBuildCommand: '',
          railpackRunCommand: '',
        ),
        railpackAutoDetectRuntimeId,
      );
      expect(
        railpackRuntimeSelectionId(
          railpackProvider: 'invalid',
          railpackBuildCommand: 'python -m build',
          railpackRunCommand: 'python app.py',
        ),
        railpackAutoDetectRuntimeId,
      );
    });
  });
}
