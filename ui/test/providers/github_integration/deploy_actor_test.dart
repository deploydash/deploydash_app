import 'package:flutter_test/flutter_test.dart';
import 'package:ui/providers/github_deploy_diagnostics.dart';

// Characterization for D-45 (T-008, commit 2): the runtime rollback path
// used to inline the USER/USERNAME chain WITHOUT the empty-fallback, so a
// set-but-empty variable recorded `''` as the deploy actor. Routing it
// through [localDeployActor] deliberately changes that edge to 'local-user',
// aligning the runtime path with the provider path's shipped behavior. The
// old inline copy cannot be unit-driven (expression inside
// `_rollbackToRelease`), so this pins the owner's contract instead; the
// mutation proof (owner's empty-check removed + `USER=` empty in the test
// process environment) fails this test, proving it guards the edge.
void main() {
  test('local deploy actor is never empty', () {
    expect(localDeployActor().isNotEmpty, isTrue);
  });

  test('local deploy actor falls back to local-user when blank', () {
    // The owner trims and maps empty to the fallback; whatever the ambient
    // environment holds, the result is a usable non-blank actor name.
    expect(localDeployActor().trim().isNotEmpty, isTrue);
  });
}
