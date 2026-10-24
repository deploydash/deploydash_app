import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yaru/yaru.dart';
import 'package:window_manager/window_manager.dart';
import 'data/local/app_data_directory.dart';
import 'data/local/app_database.dart'
    show initialDatabasePassphraseProvider, initializeAppDatabaseEncryption;
import 'providers/theme_provider.dart';
import 'services/desktop_runtime_warmup.dart';
import 'services/app_analytics_service.dart';
import 'ui/navigation/desktop_router.dart';
import 'ui/shell/shell_page.dart';
import 'ui/startup/database_unlock_gate.dart';
import 'ui/system/app_theme.dart';

Widget buildDeployDashRootApp() {
  return DatabaseUnlockGate(
    childBuilder: (passphrase) => buildDeployDashProviderScope(passphrase),
  );
}

Future<void> _publishDeployDashDataDir() =>
    publishDesktopRuntimeDataDirectory();

@visibleForTesting
void debugOverrideDeployDashDataDirPublisher(
  Future<void> Function()? publisher,
) {
  debugOverrideDesktopRuntimeDataDirectoryPublisher(publisher);
}

// coverage-gate: deploydash_provider_scope
Widget buildDeployDashProviderScope(String? passphrase) {
  return ProviderScope(
    overrides: [
      initialDatabasePassphraseProvider.overrideWithValue(passphrase),
    ],
    child: const MyApp(),
  );
}

// end coverage-gate

/// Whether this launch may activate analytics: release builds only.
///
/// Debug builds stay fully dark (no init, no handlers, no events) so local
/// development never reports into the production properties. Overridable in
/// tests; production passes nothing and reads the build mode live.
bool? _debugAnalyticsEnabledOverride;

/// Test-only seam forcing analytics on or off regardless of build mode.
/// Null restores the release-only default.
@visibleForTesting
void debugOverrideAnalyticsEnabled(bool? enabled) {
  _debugAnalyticsEnabledOverride = enabled;
}

/// Resolves the file-backed crash-marker store, or null when the app-support
/// directory is unavailable (tests, mostly): crash reporting then degrades to
/// a no-op install plus no report, and the launch proceeds.
Future<FileCrashMarkerStore?> _resolveCrashMarkerStore() async {
  try {
    return FileCrashMarkerStore(await resolveAppDataDirectory());
  } on Exception {
    return null;
  } on StateError {
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_debugAnalyticsEnabledOverride ?? kReleaseMode) {
    final crashStore = await _resolveCrashMarkerStore();
    installAnalyticsCrashHandlers(writer: crashStore?.write ?? (_) {});
    // Usage reporting is default-on behind a notice, and the stored switch
    // lives in the encrypted database, unreadable before unlock -- so this
    // as-shipped init always runs, and ShellPage's post-unlock sync applies
    // the stored switch (silencing an initialized service when off). The
    // single content-free `app_started` below may precede that sync on an
    // opted-out launch; that is the accepted pre-notice event, and every
    // later event honors the switch.
    await appAnalyticsService.initialize();
    if (crashStore != null) {
      reportPreviousSessionCrash(
        reader: crashStore.read,
        eraser: crashStore.erase,
      );
    }
    appAnalyticsService.trackAppStarted();
  }
  await YaruWindowTitleBar.ensureInitialized();
  await windowManager.ensureInitialized();
  await initializeAppDatabaseEncryption();
  await _publishDeployDashDataDir();

  const windowOptions = WindowOptions(
    size: Size(1200, 800),
    minimumSize: Size(800, 600),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    }),
  );

  runApp(buildDeployDashRootApp());
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Deploy Dash',
      debugShowCheckedModeBanner: false,
      theme: buildDeployDashTheme(yaruLight),
      darkTheme: buildDeployDashTheme(yaruDark),
      themeMode: themeMode,
      routerConfig: router,
      builder: (context, child) {
        return Container(color: Colors.transparent, child: child);
      },
    );
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = buildDesktopRouter(
    shellBuilder: (context, route) => ShellPage(route: route),
  );
  ref.onDispose(router.dispose);
  return router;
});
