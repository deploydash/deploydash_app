import 'package:ui/models/railpack_runtime.dart';
import 'package:ui/ui/project/workspace/app/app_deployment_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime helper resolves normalized provider defaults', () {
    expect(
      appDeploymentRuntimeForProvider('  PYTHON  '),
      same(railpackRuntimeForProvider('python')),
    );
  });

  test('build command helper falls back to runtime defaults', () {
    expect(
      appDeploymentResolvedBuildCommand(
        railpackProvider: 'node',
        configuredBuildCommand: null,
      ),
      'npm run build',
    );
  });

  test('run command helper falls back to runtime defaults', () {
    expect(
      appDeploymentResolvedRunCommand(
        railpackProvider: 'node',
        configuredRunCommand: null,
      ),
      'npm run start',
    );
  });

  test('repository selection helper only forwards changed repositories', () {
    final selected = <String>[];

    appDeploymentMaybeSelectUpdatedRepository(
      currentRepository: 'deploydash/example',
      nextRepository: 'deploydash/example',
      onRepositorySelected: selected.add,
    );
    appDeploymentMaybeSelectUpdatedRepository(
      currentRepository: 'deploydash/example',
      nextRepository: 'deploydash/another',
      onRepositorySelected: selected.add,
    );

    expect(selected, <String>['deploydash/another']);
  });
}
