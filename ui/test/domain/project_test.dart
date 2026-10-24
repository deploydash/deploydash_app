import 'package:ui/domain/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Project', () {
    test(
      'normalizes an explicit build command and preserves blank defaults',
      () {
        const base = Project(
          id: 'project-1',
          name: 'Docs',
          type: 'Web app',
          gitUrl: 'https://github.com/example/docs.git',
          primaryDomain: 'docs.example.com',
        );

        expect(base.effectiveBuildCommand, 'npm run build');
        expect(
          base
              .copyWith(railpackBuildCommand: '  npm run deploy  ')
              .effectiveBuildCommand,
          'npm run deploy',
        );
        expect(
          base.copyWith(railpackBuildCommand: '   ').effectiveBuildCommand,
          isEmpty,
        );
      },
    );
  });
}
