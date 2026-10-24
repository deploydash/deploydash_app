import 'dart:convert';
import 'dart:io';

import 'package:ui/native_bridge.dart';
import 'package:ui/services/deploydash_data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const bool _requireHardening = bool.fromEnvironment(
  'DEPLOYDASH_E2E_REQUIRE_HARDENING',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'release runtime hardening preserves the native Python task path',
    (_) async {
      await publishDeployDashDataDir();
      final bridge = NativeBridge();
      bridge.warmupPythonRuntime();

      final diagnostics = bridge.runtimeDiagnostics();
      expect(diagnostics, isNotNull);
      expect(diagnostics!.status, isNot('error'));
      final processSecurity = diagnostics.processSecurity;
      expect(processSecurity, isNotNull);
      expect(processSecurity!.effective, isTrue);
      if (_requireHardening) {
        expect(processSecurity.required, isTrue);
        _expectPlatformControls(processSecurity);
      }

      final started =
          jsonDecode(
                bridge.startTask(
                  jsonEncode(<String, Object?>{
                    'action': 'run_workflow',
                    'workflow_id': 'core',
                    'operation_id': 'echo',
                    'data': 'platform-runtime-security-e2e',
                  }),
                ),
              )
              as Map<String, dynamic>;
      final taskId = started['task_id'] as int;

      Map<String, dynamic>? poll;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        poll =
            jsonDecode(bridge.pollTaskEvents(taskId)) as Map<String, dynamic>;
        if (poll['done'] == true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(poll?['done'], isTrue, reason: 'Native Python task timed out.');

      final completed =
          jsonDecode(bridge.getTaskResult(taskId)) as Map<String, dynamic>;
      expect(completed['status'], 'success');
      final result = completed['result'] as Map<String, dynamic>;
      expect(result['status'], 'success');
      expect(result['data'], 'platform-runtime-security-e2e');
    },
  );
}

void _expectPlatformControls(ProcessSecurityDiagnostics diagnostics) {
  if (Platform.isLinux) {
    expect(diagnostics.platform, 'linux');
    expect(diagnostics.controls['dumpable'], 0);
    expect(diagnostics.controls['core_dumps_disabled'], isTrue);
    return;
  }
  if (Platform.isWindows) {
    expect(diagnostics.platform, 'windows');
    expect(diagnostics.controls['dll_search_hardened'], isTrue);
    expect(diagnostics.controls['no_remote_images'], isTrue);
    expect(diagnostics.controls['no_low_integrity_images'], isTrue);
    expect(diagnostics.controls['prefer_system32_images'], isTrue);
    return;
  }
  if (Platform.isMacOS) {
    expect(diagnostics.platform, 'macos');
    expect(
      diagnostics.controls['hardened_runtime_artifact_verification'],
      isTrue,
    );
    return;
  }
  fail('Unsupported E2E platform: ${Platform.operatingSystem}');
}
