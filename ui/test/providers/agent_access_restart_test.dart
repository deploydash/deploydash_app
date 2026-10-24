import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/providers/agent_access_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `AgentAccessService._clearedForThisLaunch` is static, so it survives
  // between tests in this file's isolate: the first test to run clears the
  // flag and any later one would see it already cleared and skip the write.
  // This file therefore holds exactly one test. Adding a second means adding
  // a reset seam to production code — do that deliberately, not by accident.
  test('starting the agent access service clears the flag left by a previous '
      'launch', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = AppPreferencesRepository(database);

    // A previous launch left Agent Access enabled on disk.
    await repository.setAgentAccessEnabled(true);
    expect(
      (await repository.read()).agentAccessEnabled,
      isTrue,
      reason: 'precondition: the flag is persisted across launches',
    );

    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    // This is what a launch does, and it must clear the flag before anything
    // acts on the stored value — no localhost endpoint is bound as a result.
    await container.read(agentAccessServiceProvider).initialize();

    expect(
      (await repository.read()).agentAccessEnabled,
      isFalse,
      reason: 'a relaunch must not inherit consent to bind the MCP endpoint',
    );
  });
}
