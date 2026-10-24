part of '../e2e_checklist_test.dart';

void _registerE2eChecklistTests() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Slim macOS legs never touch the manual checklist file: the sandboxed
  // macOS app cannot read repository-adjacent paths, and the slim ground
  // truth is the pinned slimMacOsChecklistKeys set validated at the end of
  // the run instead. Full flows keep the file-backed registry.
  final checklistSurfaces = _slimMacOs
      ? const <E2eChecklistSurface>[]
      : readManualE2eChecklist();
  final selectedProductionSafetyScenarios =
      _productionSafetyScenarioRequest.trim().isEmpty
      ? const <E2eScenarioDefinition>[]
      : selectProductionSafetyScenarios(_productionSafetyScenarioRequest);

  setUpAll(() async {
    debugOverrideAppAnalyticsService(_NoopAnalyticsService());
    if (_slimMacOs) {
      // Sandboxed macOS builds ignore $HOME and resolve the profile into
      // their container, which may hold a stale database from earlier runs
      // that SIP blocks clearing from outside. Point the app at a fresh
      // temp profile instead; the container tmp stays inside the sandbox.
      // Everything persisted (DB, device identity, known_hosts) resolves
      // through resolveAppDataDirectory, so all of it moves together.
      _slimE2eProfileDir = await Directory.systemTemp.createTemp(
        'slim-e2e-profile',
      );
      final profileDir = _slimE2eProfileDir!;
      debugOverrideAppDataDirectoryResolver(() async => profileDir);
    }
    await initializeAppDatabaseEncryption();
    await publishDeployDashDataDir();
  });

  tearDownAll(() async {
    writeE2eAutomationArtifacts(
      surfaces: checklistSurfaces,
      results: _runResults,
    );
    debugOverrideAppAnalyticsService(null);
    debugOverrideAppSettingsLocalBackupPickers();
    debugOverrideDatabaseUnlockBackupFilePicker(null);
    debugOverridePostgresRestoreSqlFilePicker(null);
    debugOverrideAppDataDirectoryResolver(null);
    await _slimE2eProfileDir?.delete(recursive: true);
    _slimE2eProfileDir = null;
  });

  if (!_slimMacOs) {
    test('manual E2E checklist is readable by automation', () {
      expect(checklistSurfaces.length, greaterThan(100));
      final keys = checklistSurfaces.map((surface) => surface.key).toSet();
      expect(keys.length, checklistSurfaces.length);
      for (final key in automatedChecklistKeys) {
        expect(keys, contains(key));
      }
      validateProductionSafetyScenarioRegistry(checklistSurfaces);
    });
  }

  test(
    'native Python runtime satisfies the process security contract',
    () async {
      await publishDeployDashDataDir();
      final bridge = NativeBridge();
      bridge.warmupPythonRuntime();
      final processSecurity = bridge.runtimeDiagnostics()?.processSecurity;
      expect(processSecurity, isNotNull);
      expect(processSecurity!.effective, isTrue);
      if (_requireProcessHardening) {
        expect(processSecurity.required, isTrue);
      }
    },
  );

  testWidgets(
    'fresh VM baseline checklist flow',
    (tester) async {
      // Installed here, not in setUpAll: the test binding re-asserts its
      // own error collector when each test starts, clobbering anything
      // installed earlier. Debug-only RawScrollbar assertions misfire under
      // test-driven scrolling and fail otherwise-green runs as unexpected
      // async exceptions; swallow exactly those, chain everything else.
      final previousHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (isScrollbarTestNoise(details.toString())) {
          return;
        }
        previousHandler?.call(details);
      };
      addTearDown(() {
        FlutterError.onError = previousHandler;
      });
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1200, 800));
      await windowManager.center();
      await binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => binding.setSurfaceSize(null));
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      stdout.writeln(
        'DEPLOYDASH_E2E_MODE '
        'public_health=$_verifyPublicHealthOnly '
        'caddy_cleanup=$_verifyCaddyRouteCleanupOnly '
        'worker_scheduler=$_verifyWorkerSchedulerRuntimeOnly '
        'reuse=$_reuseE2eProfile',
      );
      if (_vmHost.trim().isEmpty) {
        fail(
          'DEPLOYDASH_E2E_VM_HOST is required when DEPLOYDASH_E2E_LIVE=true.',
        );
      }

      await tester.pumpWidget(_buildE2eRootApp());
      if (_captureOnboardingUxAuditOnly) {
        // The audit walks the pre-enrollment wizard from the intro: no
        // database exists yet, so there is nothing to create or unlock.
        await _captureOnboardingUxAudit(tester, binding);
        return;
      }
      if (_reuseE2eProfile) {
        // A reused profile carries a database from the earlier run, so the
        // launch lands on unlock exactly as before.
        await _unlockLocalDatabase(tester);
        await _waitForHome(tester);
      } else {
        if (_crashBeforeFinishE2e && _crashMidSetupE2e) {
          fail('Choose one crash-injection mode per E2E run.');
        }
        if (_slimMacOs && (_crashBeforeFinishE2e || _crashMidSetupE2e)) {
          fail(
            'Crash-injection runs need the full flow: the slim leg pins its '
            'checklist set and provisions exactly once.',
          );
        }
        // Fresh installs open on onboarding; enrollment creates the
        // database at Finish inside the journey below.
        await _completeFreshServerOnboarding(tester);
        _pass('Core App Shell::Local database creation and unlock');
      }

      if (_bootstrapProductionSafetyProfileOnly) {
        stdout.writeln('DEPLOYDASH_E2E_PRODUCTION_SAFETY_BOOTSTRAP_COMPLETE');
        return;
      }
      if (selectedProductionSafetyScenarios.isNotEmpty) {
        await _runProductionSafetyScenarios(
          tester,
          binding,
          selectedProductionSafetyScenarios,
        );
        return;
      }

      if (_captureWorkspaceUxAuditOnly) {
        await _captureWorkspaceUxAudit(tester, binding);
        return;
      }
      if (_verifyPublicHealthOnly && _verifyCaddyRouteCleanupOnly) {
        fail('Choose one focused deployment verification mode per E2E run.');
      }
      if (_verifyPublicHealthOnly) {
        await _verifyPublicHealthFromHome(tester, binding);
        return;
      }
      if (_verifyCaddyRouteCleanupOnly) {
        await _verifyCaddyRouteCleanupFromHome(tester, binding);
        return;
      }
      if (_verifyWorkerSchedulerRuntimeOnly) {
        await _verifyWorkerSchedulerRuntimeFromHome(tester, binding);
        return;
      }
      if (_resumeSelectedProjectLiveAudit) {
        await _resumeSelectedProjectLiveWebAppAudit(tester, binding);
        return;
      }
      if (_captureNewProjectAuditOnly) {
        final runSuffix = DateTime.now().millisecondsSinceEpoch.remainder(
          1000000,
        );
        await _createProject(
          tester,
          name: 'E2E pre-deploy audit $runSuffix',
          runtime: 'PHP',
        );
        await _captureWebAppWorkspaceScreenshots(
          tester,
          binding,
          phase: 'before-deploy-stable',
        );
        stdout.writeln('DEPLOYDASH_E2E_CAPTURE_NEW_PROJECT_AUDIT_COMPLETE');
        return;
      }

      _pass('Core App Shell::Home dashboard after setup');

      if (_slimMacOs) {
        await _verifyBaselineStackInsideVm();
        await _exerciseSlimMacOsDeploy(tester, binding);
        _validateSlimMacOsResults();
        return;
      }

      await _exerciseTerminalCollapsedExpandedStates(tester);
      await _restartAndUnlockExistingDatabase(tester);
      await _openServerManagementFromHome(tester);
      await _captureServerOverviewScreenshots(tester, binding);
      await _exerciseServerManagementTabs(tester);
      await _verifyBaselineStackInsideVm();
      await _exerciseProjectChecklistSurfaces(tester, binding);
      await _exerciseAppSettingsSurfaces(tester);
    },
    skip: !_liveE2e,
    timeout: const Timeout(Duration(minutes: 90)),
  );

  if (!_slimMacOs) {
    test('selected production-safety scenarios passed every required row', () {
      if (selectedProductionSafetyScenarios.isEmpty) {
        return;
      }
      validateProductionSafetyResults(
        scenarios: selectedProductionSafetyScenarios,
        results: _runResults,
      );
    });
  }
}
