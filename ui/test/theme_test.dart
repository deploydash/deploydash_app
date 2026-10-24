import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/main.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/theme_provider.dart';

void main() {
  testWidgets('Theme toggling works', (WidgetTester tester) async {
    final fakePreferencesRepository = _FakeAppPreferencesRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverCatalogProvider.overrideWith(
            () => _FakeServerCatalogNotifier(
              const ServerCatalogState(
                isLoading: false,
                onboardingComplete: false,
                servers: [],
              ),
            ),
          ),
          appPreferencesRepositoryProvider.overrideWithValue(
            fakePreferencesRepository,
          ),
        ],
        child: const MyApp(),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(MaterialApp));
    // Verify initial theme mode is system
    // We can't easily read the MaterialApp.themeMode property directly from the widget tree
    // without accessing the widget itself.

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.system);

    // Find the container to access the ref
    final container = ProviderScope.containerOf(context);

    // Change theme to dark
    await container.read(themeProvider.notifier).setThemeMode(ThemeMode.dark);
    await tester.pump();

    final materialAppDark = tester.widget<MaterialApp>(
      find.byType(MaterialApp),
    );
    expect(materialAppDark.themeMode, ThemeMode.dark);

    // Change theme to light
    await container.read(themeProvider.notifier).setThemeMode(ThemeMode.light);
    await tester.pump();

    final materialAppLight = tester.widget<MaterialApp>(
      find.byType(MaterialApp),
    );
    expect(materialAppLight.themeMode, ThemeMode.light);
  });
}

class _FakeAppPreferencesRepository implements AppPreferencesRepository {
  @override
  Future<AppPreferencesRecord> read() async {
    return AppPreferencesRecord(
      terminalDebugView: false,
      themeMode: 'system',
      gitHubPendingOauthState: null,
      sqliteBackupS3Config: null,
      agentAccessEnabled: false,
      agentAccessPermissionMode: agentAccessPermissionReadOnly,
      agentSessionToken: null,
      agentSessionExpiresAt: null,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {}

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {}

  @override
  Future<void> setGitHubPendingOauthState(String? oauthState) async {}

  @override
  Future<void> setTerminalDebugView(bool enabled) async {}

  @override
  Future<void> setThemeMode(String mode) async {}

  @override
  Future<void> setAgentAccessEnabled(bool enabled) async {}

  @override
  Future<void> setAgentAccessPermissionMode(String mode) async {}

  @override
  Future<void> issueAgentSession({
    required String token,
    required DateTime expiresAt,
  }) async {}

  @override
  Future<void> clearAgentSession() async {}

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {}

  @override
  Future<void> setTelemetryEnabled({required bool enabled}) async {}

  @override
  Future<void> markTelemetryNoticeShown() async {}

  @override
  Future<void> markTelemetryNagShown() async {}
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._seedState);

  final ServerCatalogState _seedState;

  @override
  ServerCatalogState build() => _seedState;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> selectServer(String serverId) async {
    state = state.copyWith(selectedServerId: serverId);
  }
}
